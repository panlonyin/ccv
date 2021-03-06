extern "C" {
#include "cog.h"
}
#include "cublas_v2.h"

// this structure holds intermediate on-device memory representation of convnet
typedef struct {
	ccv_convnet_layer_t* layers;
	ccv_convnet_layer_t* updates;
} cog_convnet_t;

#define GPU(x) ((cog_convnet_t*)((x)->reserved))

static inline void _ccv_convnet_layer_deduce_output_format(int a_rows, int a_cols, ccv_convnet_layer_t* layer, int* rows, int* cols)
{
	assert(rows != 0 && cols != 0);
	switch(layer->type)
	{
		case CCV_CONVNET_CONVOLUTIONAL:
			assert(layer->net.convolutional.rows % 2); // as of now, don't support even number of kernel size
			assert(layer->net.convolutional.cols % 2);
			assert((a_rows + layer->net.convolutional.border * 2 - layer->net.convolutional.rows) % layer->net.convolutional.strides == 0);
			assert((a_cols + layer->net.convolutional.border * 2 - layer->net.convolutional.cols) % layer->net.convolutional.strides == 0);
			*rows = (a_rows + layer->net.convolutional.border * 2 - layer->net.convolutional.rows) / layer->net.convolutional.strides + 1;
			*cols = (a_cols + layer->net.convolutional.border * 2 - layer->net.convolutional.cols) / layer->net.convolutional.strides + 1;
			break;
		case CCV_CONVNET_FULL_CONNECT:
			*rows = layer->net.full_connect.count;
			*cols = 1;
			break;
		case CCV_CONVNET_MAX_POOL:
		case CCV_CONVNET_AVERAGE_POOL:
			assert((a_rows + layer->net.pool.border * 2 - layer->net.pool.size) % layer->net.pool.strides == 0);
			assert((a_cols + layer->net.pool.border * 2 - layer->net.pool.size) % layer->net.pool.strides == 0);
			*rows = (a_rows + layer->net.pool.border * 2 - layer->net.pool.size) / layer->net.pool.strides + 1;
			*cols = (a_cols + layer->net.pool.border * 2 - layer->net.pool.size) / layer->net.pool.strides + 1;
			break;
	}
}

static void _cog_convnet_reserve_on_device(ccv_convnet_t* convnet)
{
	assert(GPU(convnet) == 0);
	convnet->reserved = (cog_convnet_t*)ccmalloc(sizeof(cog_convnet_t) + sizeof(ccv_convnet_layer_t) * convnet->count * 2);
	GPU(convnet)->layers = (ccv_convnet_layer_t*)(GPU(convnet) + 1);
	GPU(convnet)->updates = GPU(convnet)->layers + convnet->count;
	memcpy(GPU(convnet)->layers, convnet->layers, sizeof(ccv_convnet_layer_t) * convnet->count);
	memcpy(GPU(convnet)->updates, convnet->layers, sizeof(ccv_convnet_layer_t) * convnet->count);
	ccv_convnet_layer_t* layers = GPU(convnet)->layers;
	ccv_convnet_layer_t* updates = GPU(convnet)->updates;
	int i;
	for (i = 0; i < convnet->count; i++)
		switch (layers[i].type)
		{
			case CCV_CONVNET_CONVOLUTIONAL:
				assert(updates[i].type == CCV_CONVNET_CONVOLUTIONAL);
				layers[i].w = 0;
				cudaMalloc(&layers[i].w, sizeof(float) * (layers[i].wnum + layers[i].net.convolutional.count));
				assert(layers[i].w);
				layers[i].bias = layers[i].w + layers[i].wnum;
				// this is wrong, I need to rewind w
				cudaMemcpy(layers[i].w, convnet->layers[i].w, sizeof(float) * (layers[i].wnum + layers[i].net.convolutional.count), cudaMemcpyHostToDevice);
				updates[i].w = 0;
				cudaMalloc(&updates[i].w, sizeof(float) * (updates[i].wnum * 8 * 55 + updates[i].net.convolutional.count));
				assert(updates[i].w);
				updates[i].bias = updates[i].w + updates[i].wnum * 8 * 55;
				break;
			case CCV_CONVNET_FULL_CONNECT:
				assert(updates[i].type == CCV_CONVNET_FULL_CONNECT);
				layers[i].w = 0;
				cudaMalloc(&layers[i].w, sizeof(float) * (layers[i].wnum + layers[i].net.full_connect.count));
				assert(layers[i].w);
				layers[i].bias = layers[i].w + layers[i].wnum;
				cudaMemcpy(layers[i].w, convnet->layers[i].w, sizeof(float) * (layers[i].wnum + layers[i].net.full_connect.count), cudaMemcpyHostToDevice);
				updates[i].w = 0;
				cudaMalloc(&updates[i].w, sizeof(float) * (updates[i].wnum + updates[i].net.full_connect.count));
				updates[i].bias = updates[i].w + updates[i].wnum;
				break;
			case CCV_CONVNET_MAX_POOL:
			case CCV_CONVNET_AVERAGE_POOL:
				assert(updates[i].type == layers[i].type);
				updates[i].w = updates[i].bias = 0;
				layers[i].w = layers[i].bias = 0;
				break;
		}
}

// =========================================== KERNEL CODE ===================================================

template <int input_per_thread, int filter_per_thread>
__global__ void _cog_kern_convolutional_forward_propagate(const int strides, const int border, const int batch,
		float* input, const int rows, const int cols, const int channels,
		float* out, const int out_rows, const int out_cols,
		float* filter, const int filter_rows, const int filter_cols, const int count,
		float* const biases)
{
	// gridDim.x == out_rows
	// gridDim.y == out_cols
	extern __shared__ float shared[];
	float* shared_block = &shared[0];
	float* shared_weights = &shared[batch];
	float* shared_bias = &shared[batch + count];
	float prod[filter_per_thread][input_per_thread];
	assert(batch == input_per_thread * blockDim.x);
	assert(count == filter_per_thread * blockDim.y);
	const int thidx = threadIdx.x + threadIdx.y * blockDim.x;
	const int thcnt = blockDim.x * blockDim.y;
	const int input_loads = (batch + thcnt - 1) / thcnt;
	const int filter_loads = (count + thcnt - 1) / thcnt;
	int c, i, j, x, y;
	#pragma unroll
	for (i = 0; i < filter_per_thread; i++)
		#pragma unroll
		for (j = 0; j < input_per_thread; j++)
			prod[i][j] = 0;
	input += (blockIdx.x * strides * cols + blockIdx.y * strides) * batch;
	#pragma unroll
	for (i = 0; i < filter_loads; i++)
		if (i * thcnt + thidx < count)
			shared_bias[i * thcnt + thidx] = biases[i * thcnt + thidx];
	for (c = 0; c < channels; c++)
	{
		for (y = 0; y < filter_rows; y++)
		{
			const int iy = y + blockIdx.x * strides - border;
			if (iy >= 0 && iy < rows)
				for (x = 0; x < filter_cols; x++)
				{
					const int ix = x + blockIdx.y * strides - border;
					if (ix >= 0 && ix < cols)
					{
						#pragma unroll
						for (i = 0; i < input_loads; i++)
							if (i * thcnt + thidx < batch)
								shared_block[i * thcnt + thidx] = input[((y - border) * cols + x - border) * batch + i * thcnt + thidx];
						#pragma unroll
						for (i = 0; i < filter_loads; i++)
							if (i * thcnt + thidx < count)
								shared_weights[i * thcnt + thidx] = filter[(y * filter_cols + x) * count + i * thcnt + thidx];
						__syncthreads();
						#pragma unroll
						for (i = 0; i < filter_per_thread; i++)
							#pragma unroll
							for (j = 0; j < input_per_thread; j++)
								prod[i][j] += shared_block[j + threadIdx.x * input_per_thread] * shared_weights[i + threadIdx.y * filter_per_thread];
						__syncthreads();
					}
				}
		}
		input += rows * cols * batch;
		filter += filter_rows * filter_cols * count;
	}
	const int outcnt = out_rows * out_cols * batch;
	out += (blockIdx.x * out_cols + blockIdx.y) * batch;
	#pragma unroll
	for (i = 0; i < filter_per_thread; i++)
	{
		const float bias = shared_bias[i + threadIdx.y * filter_per_thread];
		#pragma unroll
		for (j = 0; j < input_per_thread; j++)
			out[(i + threadIdx.y * filter_per_thread) * outcnt + j + threadIdx.x * input_per_thread] = max(0.0, prod[i][j] + bias);
	}
}

static void _cog_convolutional_forward_propagate(ccv_convnet_layer_t* layer, int batch, int rows, int cols, int ch, float* a, float** b, const cudaStream_t& stream)
{
	int out_rows, out_cols;
	_ccv_convnet_layer_deduce_output_format(rows, cols, layer, &out_rows, &out_cols);
	assert(b);
	float* db = *b;
	if (!db)
		cudaMalloc(&db, sizeof(float) * out_rows * out_cols * layer->net.convolutional.count * batch);
	*b = db;
	dim3 threads_per_block(batch / 8, layer->net.convolutional.count / 4);
	dim3 num_blocks(out_rows, out_cols);
	int shared_memory_size = sizeof(float) * (batch + layer->net.convolutional.count);
	_cog_kern_convolutional_forward_propagate
		<8, 4>
		<<<num_blocks, threads_per_block, shared_memory_size + /* need extra space for bias */ sizeof(float) * layer->net.convolutional.count, stream>>>
		(layer->net.convolutional.strides, layer->net.convolutional.border, batch,
		 a, rows, cols, ch,
		 db, out_rows, out_cols,
		 layer->w, layer->net.convolutional.rows, layer->net.convolutional.cols, layer->net.convolutional.count,
		 layer->bias);
}

template <int channel_per_thread, int filter_per_thread, int batch_per_block>
__global__ void _cog_kern_convolutional_backward_propagate_delta(const int strides, const int border, const int batch,
		float* input, const int rows, const int cols, const int channels,
		float* out, float* out_grad, const int out_rows, const int out_cols,
		float* delta,
		float* filter, const int filter_rows, const int filter_cols, const int count)
{
	// gridDim.x == filter_rows
	// gridDim.y == filter_cols
	assert(gridDim.z == out_rows * batch / batch_per_block);
	extern __shared__ float shared[];
	float* shared_block = &shared[0];
	float* shared_out = &shared[batch_per_block * channels];
	float* shared_grad = &shared[batch_per_block * (channels + count)];
	float prod[channel_per_thread][filter_per_thread];
	// channel_per_thread * blockDim.x == channels
	// filter_per_thread * blockDim.y == filter_count
	assert(channel_per_thread * blockDim.x == channels);
	assert(filter_per_thread * blockDim.y == count);
	const int thidx = threadIdx.x + threadIdx.y * blockDim.x;
	const int thcnt = blockDim.x * blockDim.y;
	assert(batch % batch_per_block == 0);
	assert(thcnt % batch_per_block == 0);
	int i, j, k, x;
	#pragma unroll
	for (i = 0; i < channel_per_thread; i++)
		#pragma unroll
		for (j = 0; j < filter_per_thread; j++)
			prod[i][j] = 0;
	const int bxidx = thidx % batch_per_block;
	const int byidx = thidx / batch_per_block;
	const int batch_idx = blockIdx.z % (batch / batch_per_block);
	const int incnt = rows * cols * batch;
	input += (blockIdx.x * cols + blockIdx.y) * batch + batch_idx * batch_per_block + byidx * incnt + bxidx;
	const int outcnt = out_rows * out_cols * batch;
	const int block_loads = (batch_per_block * channels + thcnt - 1) / thcnt;
	const int out_loads = (batch_per_block * count + thcnt - 1) / thcnt;
	const int block_loads_factor = (thcnt / batch_per_block) * incnt;
	const int out_loads_factor = (thcnt / batch_per_block) * outcnt;
	const int filter_idx = threadIdx.y * filter_per_thread;
	const int channel_idx = threadIdx.x * channel_per_thread;
	const int y = blockIdx.z / (batch / batch_per_block);
	out += batch_idx * batch_per_block + byidx * outcnt + bxidx + y * out_cols * batch;
	out_grad += batch_idx * batch_per_block + byidx * outcnt + bxidx + y * out_cols * batch;
	const int iy = blockIdx.x + y * strides - border;
	if (iy >= 0 && iy < rows)
	{
		input += (y * strides - border) * cols * batch;
		for (x = 0; x < out_cols; x++)
		{
			const int ix = blockIdx.y + x * strides - border;
			if (ix >= 0 && ix < cols)
			{
				#pragma unroll
				for (i = 0; i < block_loads; i++)
					if (thidx + i * thcnt < batch_per_block * channels)
						shared_block[thidx + i * thcnt] = input[(x * strides - border) * batch + i * block_loads_factor];
				#pragma unroll
				for (i = 0; i < out_loads; i++)
					if (thidx + i * thcnt < batch_per_block * count)
						shared_out[thidx + i * thcnt] = out[x * batch + i * out_loads_factor],
						shared_grad[thidx + i * thcnt] = out_grad[x * batch + i * out_loads_factor];
				__syncthreads();
				#pragma unroll
				for (k = 0; k < batch_per_block; k++)
					#pragma unroll
					for (i = 0; i < filter_per_thread; i++)
						if (shared_out[(i + filter_idx) * batch_per_block + k] > 0)
							#pragma unroll
							for (j = 0; j < channel_per_thread; j++)
								prod[j][i] += shared_block[(j + channel_idx) * batch_per_block + k] * shared_grad[(i + filter_idx) * batch_per_block + k];
				__syncthreads();
			}
		}
	}
	delta += (blockIdx.x * filter_cols + blockIdx.y) * count + blockIdx.z * filter_rows * filter_cols * count * channels;
	const int deltacnt = filter_rows * filter_cols * count;
	#pragma unroll
	for (i = 0; i < channel_per_thread; i++)
		#pragma unroll
		for (j = 0; j < filter_per_thread; j++)
			delta[(i + channel_idx) * deltacnt + j + filter_idx] = prod[i][j];
}

template <int out_per_thread>
__global__ void _cog_kern_convolutional_backward_propagate_bias(const int batch,
		float* out, float* out_grad, const int out_rows, const int out_cols,
		float* bias, const int count)
{
	// gridDim.x == count
	assert(gridDim.x == count);
	const int skip_pixels = blockDim.y;
	extern __shared__ float shared[];
	float* shared_bias = &shared[0];
	float* shared_out = &shared[1];
	float* shared_grad = &shared[1 + batch * skip_pixels];
	int i, x;
	const int thidx = threadIdx.x + threadIdx.y * blockDim.x;
	const int thcnt = blockDim.x * blockDim.y;
	const int out_loads = (batch * skip_pixels + thcnt - 1) / thcnt;
	assert(thcnt % batch == 0);
	out += blockIdx.x * out_rows * out_cols * batch + thidx;
	out_grad += blockIdx.x * out_rows * out_cols * batch + thidx;
	const int out_load_factor = thcnt;
	const int out_load_pixels = thcnt / batch;
	if (thidx == 0)
		shared_bias[0] = 0;
	for (x = 0; x < out_rows * out_cols; x += skip_pixels)
	{
		for (i = 0; i < out_loads; i++)
			if (i * thcnt + thidx < batch * skip_pixels && x + i * out_load_pixels < out_rows * out_cols)
				shared_out[i * thcnt + thidx] = out[x * batch + i * out_load_factor],
				shared_grad[i * thcnt + thidx] = out_grad[x * batch + i * out_load_factor];
		__syncthreads();
		// because I branched out with threadIdx, therefore, synchronization must happen outside of the if clause
		if (threadIdx.y + x < out_rows * out_cols)
		{
			if (shared_out[threadIdx.y * batch + threadIdx.x * out_per_thread] <= 0)
				shared_grad[threadIdx.y * batch + threadIdx.x * out_per_thread] = 0;
			#pragma unroll
			for (i = 1; i < out_per_thread; i++)
				if (shared_out[threadIdx.y * batch + threadIdx.x * out_per_thread + i] > 0)
					shared_grad[threadIdx.y * batch + threadIdx.x * out_per_thread] += shared_grad[threadIdx.y * batch + threadIdx.x * out_per_thread + i];
		}
		__syncthreads();
		// I can do better here, but bias computation is not the bottleneck
		if (threadIdx.y + x < out_rows * out_cols && threadIdx.x == 0)
			#pragma unroll
			for (i = 1; i < blockDim.x; i++)
				shared_grad[threadIdx.y * batch] += shared_grad[threadIdx.y * batch + i * out_per_thread];
		__syncthreads();
		// because I branched out with threadIdx, therefore, synchronization must happen outside of the if clause, thus, this if clause appeared repeatedly
		if (threadIdx.y + x < out_rows * out_cols && thidx == 0)
		{
			#pragma unroll
			for (i = 1; i < blockDim.y && i + x < out_rows * out_cols; i++)
				shared_grad[0] += shared_grad[i * batch];
			shared_bias[0] += shared_grad[0];
		}
		__syncthreads();
	}
	if (thidx == 0)
		bias[blockIdx.x] = shared_bias[0];
}

template <int input_per_thread, int channel_per_thread, int filter_per_iteration>
__global__ void _cog_kern_convolutional_backward_propagate(const int strides, const int border, const int batch,
		float* input_grad, const int rows, const int cols, const int channels,
		float* out, float* out_grad, const int out_rows, const int out_cols,
		float* filter, const int filter_rows, const int filter_cols, const int count)
{
	// gridDim.x = rows
	// gridDim.y = cols
	extern __shared__ float shared[];
	float* shared_out = &shared[0];
	float* shared_grad = &shared[batch];
	float* shared_weights = &shared[batch * 2];
	float prod[input_per_thread][channel_per_thread];
	assert(batch == input_per_thread * blockDim.x);
	assert(channels == channel_per_thread * blockDim.y);
	const int thidx = threadIdx.x + threadIdx.y * blockDim.x;
	const int thcnt = blockDim.x * blockDim.y;
	const int input_loads = (batch + thcnt - 1) / thcnt;
	const int channel_filter_loads = (channels * filter_per_iteration + thcnt - 1) / thcnt;
	int i, j, k, c, x, y;
	#pragma unroll
	for (i = 0; i < input_per_thread; i++)
		#pragma unroll
		for (j = 0; j < channel_per_thread; j++)
			prod[i][j] = 0;
	const int ycnt = (filter_rows - 1 - (blockIdx.x + border) % strides) / strides + 1;
	const int xcnt = (filter_cols - 1 - (blockIdx.y + border) % strides) / strides + 1;
	const int filter_y = (ycnt - 1) * strides + (blockIdx.x + border) % strides;
	assert(filter_y < filter_rows);
	const int filter_x = (xcnt - 1) * strides + (blockIdx.y + border) % strides;
	assert(filter_x < filter_cols);
	const int out_y = (blockIdx.x + border) / strides - ycnt + 1;
	const int out_x = (blockIdx.y + border) / strides - xcnt + 1;
	const int out_start_y = max(out_y, 0);
	const int out_start_x = max(out_x, 0);
	const int filter_start_y = filter_y - (out_start_y - out_y) * strides;
	const int filter_start_x = filter_x - (out_start_x - out_x) * strides;
	out += (out_start_y * out_cols + out_start_x) * batch;
	out_grad += (out_start_y * out_cols + out_start_x) * batch;
	const int out_end_y = out_y + ycnt - 1;
	const int out_end_x = out_x + xcnt - 1;
	const int filter_end_y = (blockIdx.x + border) % strides + (out_end_y - min(out_end_y, out_rows - 1)) * strides;
	const int filter_end_x = (blockIdx.y + border) % strides + (out_end_x - min(out_end_x, out_cols - 1)) * strides;
	const int outcnt = out_rows * out_cols * batch;
	for (y = filter_start_y; y >= filter_end_y; y -= strides)
	{
		for (x = filter_start_x, c = 0; x >= filter_end_x; x -= strides, c++)
		{
			#pragma unroll
			for (k = 0; k < count; k++)
			{
				if (k % filter_per_iteration == 0)
				{
					const int min_channel_filter_count = channels * min(filter_per_iteration, count - k);
					#pragma unroll
					for (i = 0; i < channel_filter_loads; i++)
						if (i * thcnt + thidx < min_channel_filter_count)
						{
							const int channel_idx = (i * thcnt + thidx) / filter_per_iteration;
							const int filter_idx = (i * thcnt + thidx) % filter_per_iteration + k;
							shared_weights[i * thcnt + thidx] = filter[(channel_idx * filter_rows * filter_cols + y * filter_cols + x) * count + filter_idx];
						}
				}
				float* out_per_filter = out + k * outcnt;
				float* out_grad_per_filter = out_grad + k * outcnt;
				#pragma unroll
				for (i = 0; i < input_loads; i++)
					if (i * thcnt + thidx < batch)
						shared_out[i * thcnt + thidx] = out_per_filter[c * batch + i * thcnt + thidx],
						shared_grad[i * thcnt + thidx] = out_grad_per_filter[c * batch + i * thcnt + thidx];
				__syncthreads();
				const int k_idx = k % filter_per_iteration;
				#pragma unroll
				for (i = 0; i < input_per_thread; i++)
					if (shared_out[i + threadIdx.x * input_per_thread] > 0)
						#pragma unroll
						for (j = 0; j < channel_per_thread; j++)
							prod[i][j] += shared_grad[i + threadIdx.x * input_per_thread] * shared_weights[(j + threadIdx.y * channel_per_thread) * filter_per_iteration + k_idx];
				__syncthreads();
			}
		}
		out += out_cols * batch;
		out_grad += out_cols * batch;
	}
	const int incnt = rows * cols * batch;
	input_grad += (blockIdx.x * cols + blockIdx.y) * batch;
	#pragma unroll
	for (i = 0; i < channel_per_thread; i++)
		#pragma unroll
		for (j = 0; j < input_per_thread; j++)
			input_grad[(i + threadIdx.y * channel_per_thread) * incnt + j + threadIdx.x * input_per_thread] = prod[j][i];
}

static void _cog_convnet_convolutional_backward_propagate(ccv_convnet_layer_t* layer, int batch, int rows, int cols, int ch, float* a, float* n, float* m, float** b, ccv_convnet_layer_t* update, const cudaStream_t& stream)
{
	assert(layer->net.convolutional.count % 4 == 0);
	int out_rows, out_cols;
	_ccv_convnet_layer_deduce_output_format(rows, cols, layer, &out_rows, &out_cols);
	dim3 threads_per_block_for_delta(ch, layer->net.convolutional.count);
	assert(batch % 16 == 0);
	dim3 num_blocks_for_delta(layer->net.convolutional.rows, layer->net.convolutional.cols, out_rows * batch / 16);
	int shared_memory_size = sizeof(float) * (16 * (ch + layer->net.convolutional.count * 2));
	cudaFuncSetCacheConfig(_cog_kern_convolutional_backward_propagate_delta<1, 1, 16>, cudaFuncCachePreferShared);
	_cog_kern_convolutional_backward_propagate_delta
	<1, 1, 16>
	<<<num_blocks_for_delta, threads_per_block_for_delta, shared_memory_size, stream>>>
	(layer->net.convolutional.strides, layer->net.convolutional.border, batch,
		m, rows, cols, ch,
		n, a, out_rows, out_cols,
		update->w,
		layer->w, layer->net.convolutional.rows, layer->net.convolutional.cols, layer->net.convolutional.count);
	dim3 threads_per_block_for_bias(batch / 8, 8);
	dim3 num_blocks_for_bias(layer->net.convolutional.count);
	shared_memory_size = sizeof(float) * (1 + batch * 8 * 2);
	cudaFuncSetCacheConfig(_cog_kern_convolutional_backward_propagate_bias<8>, cudaFuncCachePreferShared);
	_cog_kern_convolutional_backward_propagate_bias
	<8>
	<<<num_blocks_for_bias, threads_per_block_for_bias, shared_memory_size, stream>>>
	(batch,
		n, a, out_rows, out_cols,
		update->bias, layer->net.convolutional.count);
	assert(b);
	float* db = *b;
	if (!db)
		cudaMalloc(&db, sizeof(float) * rows * cols * ch * batch);
	*b = db;
	dim3 threads_per_block(batch, 1);
	dim3 num_blocks(rows, cols);
	shared_memory_size = sizeof(float) * (batch * 2 + ch * 48);
	_cog_kern_convolutional_backward_propagate
	<1, 3, 48>
	<<<num_blocks, threads_per_block, shared_memory_size, stream>>>
	(layer->net.convolutional.strides, layer->net.convolutional.border, batch,
	 db, rows, cols, ch,
	 n, a, out_rows, out_cols,
	 layer->w, layer->net.convolutional.rows, layer->net.convolutional.cols, layer->net.convolutional.count);
}

template <int input_per_thread>
__global__ void _cog_kern_max_pool_forward_propagate(const int strides, const int border, const int size, const int batch,
		float* input, const int rows, const int cols, const int channels,
		float* out, const int out_rows, const int out_cols)
{
	// gridDim.x == out_rows
	// gridDim.y == out_cols
	// gridDim.z == channels
	assert(gridDim.x == out_rows);
	assert(gridDim.y == out_cols);
	assert(gridDim.z == channels);
	extern __shared__ float shared[];
	float* shared_input = &shared[0];
	const int thcnt = blockDim.x;
	const int thidx = threadIdx.x;
	const int input_loads = (batch + thcnt - 1) / thcnt;
	int i, x, y;
	input += blockIdx.z * rows * cols * batch + (blockIdx.x * strides * cols + blockIdx.y * strides) * batch;
	float prod[input_per_thread];
	const int input_y = blockIdx.x * strides - border;
	const int input_x = blockIdx.y * strides - border;
	const int input_start_y = max(input_y, 0);
	const int input_start_x = max(input_x, 0);
	const int input_end_y = min(input_y + size, rows);
	const int input_end_x = min(input_x + size, cols);
	const int size_start_y = input_start_y - input_y - border;
	const int size_start_x = input_start_x - input_x - border;
	const int size_end_y = size - border + (input_end_y - (input_y + size));
	const int size_end_x = size - border + (input_end_x - (input_x + size));
	// this is equal to iterating over 0 to size, and then compute the input origin by blockIdx.x * strides - border + y
	#pragma unroll
	for (y = size_start_y; y < size_end_y; y++)
		#pragma unroll
		for (x = size_start_x; x < size_end_x; x++)
		{
			#pragma unroll
			for (i = 0; i < input_loads; i++)
				if (i * thcnt + thidx < batch)
					shared_input[i * thcnt + thidx] = input[(y * cols + x) * batch + i * thcnt + thidx];
			__syncthreads();
			if (x == size_start_x && y == size_start_y)
				#pragma unroll
				for (i = 0; i < input_per_thread; i++)
					prod[i] = shared_input[i + threadIdx.x * input_per_thread];
			else
				#pragma unroll
				for (i = 0; i < input_per_thread; i++)
					prod[i] = max(prod[i], shared_input[i + threadIdx.x * input_per_thread]);
			__syncthreads();
		}
	out += blockIdx.z * out_rows * out_cols * batch + (blockIdx.x * out_cols + blockIdx.y) * batch;
	#pragma unroll
	for (i = 0; i < input_per_thread; i++)
		out[i + threadIdx.x * input_per_thread] = prod[i];
}

static void _cog_convnet_max_pool_forward_propagate(ccv_convnet_layer_t* layer, int batch, int rows, int cols, int ch, float* a, float** b, const cudaStream_t& stream)
{
	int out_rows, out_cols;
	_ccv_convnet_layer_deduce_output_format(rows, cols, layer, &out_rows, &out_cols);
	float* db = *b;
	if (!db)
		cudaMalloc(&db, sizeof(float) * out_rows * out_cols * ch * batch);
	*b = db;
	dim3 num_blocks(out_rows, out_cols, ch);
	dim3 threads_per_block(batch);
	int shared_memory_size = sizeof(float) * batch;
	_cog_kern_max_pool_forward_propagate
	<1>
	<<<num_blocks, threads_per_block, shared_memory_size, stream>>>
	(layer->net.pool.strides, layer->net.pool.border, layer->net.pool.size, batch,
	 a, rows, cols, ch,
	 db, out_rows, out_cols);
}

template <int input_per_thread>
__global__ void _cog_kern_max_pool_backward_propagate(const int strides, const int border, const int size, const int batch,
		float* input, float* input_grad, const int rows, const int cols, const int channels,
		float* out, float* out_grad, const int out_rows, int out_cols)
{
	// gridDim.x == rows
	// gridDim.y == cols
	// gridDim.z == channels
	assert(gridDim.x == rows);
	assert(gridDim.y == cols);
	assert(gridDim.z == channels);
	extern __shared__ float shared[];
	float* shared_input = &shared[0];
	float* shared_out = &shared[batch];
	float* shared_grad = &shared[batch * 2];
	const int thcnt = blockDim.x;
	const int thidx = threadIdx.x;
	const int input_loads = (batch + thcnt - 1) / thcnt;
	float prod[input_per_thread];
	int i, x, y;
	#pragma unroll
	for (i = 0; i < input_per_thread; i++)
		prod[i] = 0;
	const int ycnt = (size - 1 - (blockIdx.x + border) % strides) / strides + 1;
	const int xcnt = (size - 1 - (blockIdx.y + border) % strides) / strides + 1;
	const int out_y = (blockIdx.x + border) / strides - ycnt + 1;
	const int out_x = (blockIdx.y + border) / strides - xcnt + 1;
	const int out_start_y = max(out_y, 0);
	const int out_start_x = max(out_x, 0);
	out += (blockIdx.z * out_rows * out_cols + out_start_y * out_cols) * batch;
	out_grad += (blockIdx.z * out_rows * out_cols + out_start_y * out_cols) * batch;
	const int out_end_y = min(out_y + ycnt, out_rows);
	const int out_end_x = min(out_x + xcnt, out_cols);
	input += (blockIdx.z * rows * cols + blockIdx.x * cols + blockIdx.y) * batch;
	for (i = 0; i < input_loads; i++)
		if (i * thcnt + thidx < batch)
			shared_input[i * thcnt + thidx] = input[i * thcnt + thidx];
	for (y = out_start_y; y < out_end_y; y++)
	{
		for (x = out_start_x; x < out_end_x; x++)
		{
			#pragma unroll
			for (i = 0; i < input_loads; i++)
				if (i * thcnt + thidx < batch)
					shared_out[i * thcnt + thidx] = out[x * batch + i * thcnt + thidx],
					shared_grad[i * thcnt + thidx] = out_grad[x * batch + i * thcnt + thidx];
			__syncthreads();
			#pragma unroll
			for (i = 0; i < input_per_thread; i++)
			{
				float vi = shared_input[i + threadIdx.x * input_per_thread];
				float vo = shared_out[i + threadIdx.x * input_per_thread];
				float delta = fabsf(vi - vo) / max(max(vi, vo), 1e-5);
				if (delta < 1e-5) // there seems to be a bug that the direct comparison of these two float number will have different result on GPU comparing with CPU result
				// if (shared_out[i + threadIdx.x * input_per_thread] == shared_input[i + threadIdx.x * input_per_thread]) // if we don't care of accuracy and needs that extra 4ms per batch, we can change to this line
					prod[i] += shared_grad[i + threadIdx.x * input_per_thread];
			}
			__syncthreads();
		}
		out += out_cols * batch;
		out_grad += out_cols * batch;
	}
	input_grad += (blockIdx.z * rows * cols + blockIdx.x * cols + blockIdx.y) * batch;
	#pragma unroll
	for (i = 0; i < input_per_thread; i++)
		input_grad[i + threadIdx.x * input_per_thread] = prod[i];
}

static void _cog_convnet_max_pool_backward_propagate(ccv_convnet_layer_t* layer, int batch, int rows, int cols, int ch, float* a, float* n, float* m, float** b, const cudaStream_t& stream)
{
	int out_rows, out_cols;
	_ccv_convnet_layer_deduce_output_format(rows, cols, layer, &out_rows, &out_cols);
	float* db = *b;
	if (!db)
		cudaMalloc(&db, sizeof(float) * rows * cols * ch * batch);
	*b = db;
	dim3 num_blocks(rows, cols, ch);
	dim3 threads_per_block(batch);
	int shared_memory_size = sizeof(float) * batch * 3;
	_cog_kern_max_pool_backward_propagate
	<1>
	<<<num_blocks, threads_per_block, shared_memory_size, stream>>>
	(layer->net.pool.strides, layer->net.pool.border, layer->net.pool.size, batch,
	 m, db, rows, cols, ch,
	 n, a, out_rows, out_cols);
}

template <int input_per_thread>
__global__ void _cog_kern_average_pool_forward_propagate(const int strides, const int border, const int size, const int batch,
		float* input, const int rows, const int cols, const int channels,
		float* out, const int out_rows, const int out_cols)
{
	// gridDim.x == out_rows
	// gridDim.y == out_cols
	// gridDim.z == channels
	assert(gridDim.x == out_rows);
	assert(gridDim.y == out_cols);
	assert(gridDim.z == channels);
	extern __shared__ float shared[];
	float* shared_input = &shared[0];
	const int thcnt = blockDim.x;
	const int thidx = threadIdx.x;
	const int input_loads = (batch + thcnt - 1) / thcnt;
	int i, x, y;
	input += blockIdx.z * rows * cols * batch + (blockIdx.x * strides * cols + blockIdx.y * strides) * batch;
	float prod[input_per_thread];
	#pragma unroll
	for (i = 0; i < input_per_thread; i++)
		prod[i] = 0;
	const int input_y = blockIdx.x * strides - border;
	const int input_x = blockIdx.y * strides - border;
	const int input_start_y = max(input_y, 0);
	const int input_start_x = max(input_x, 0);
	const int input_end_y = min(input_y + size, rows);
	const int input_end_x = min(input_x + size, cols);
	const int size_start_y = input_start_y - input_y - border;
	const int size_start_x = input_start_x - input_x - border;
	const int size_end_y = size - border + (input_end_y - (input_y + size));
	const int size_end_x = size - border + (input_end_x - (input_x + size));
	// this is equal to iterating over 0 to size, and then compute the input origin by blockIdx.x * strides - border + y
	#pragma unroll
	for (y = size_start_y; y < size_end_y; y++)
		#pragma unroll
		for (x = size_start_x; x < size_end_x; x++)
		{
			#pragma unroll
			for (i = 0; i < input_loads; i++)
				if (i * thcnt + thidx < batch)
					shared_input[i * thcnt + thidx] = input[(y * cols + x) * batch + i * thcnt + thidx];
			__syncthreads();
			#pragma unroll
			for (i = 0; i < input_per_thread; i++)
				prod[i] += shared_input[i + threadIdx.x * input_per_thread];
			__syncthreads();
		}
	float inv_size = 1.0 / ((input_end_y - input_start_y) * (input_end_x - input_start_x));
	out += blockIdx.z * out_rows * out_cols * batch + (blockIdx.x * out_cols + blockIdx.y) * batch;
	#pragma unroll
	for (i = 0; i < input_per_thread; i++)
		out[i + threadIdx.x * input_per_thread] = prod[i] * inv_size;
}

static void _cog_convnet_average_pool_forward_propagate(ccv_convnet_layer_t* layer, int batch, int rows, int cols, int ch, float* a, float** b, const cudaStream_t& stream)
{
	int out_rows, out_cols;
	_ccv_convnet_layer_deduce_output_format(rows, cols, layer, &out_rows, &out_cols);
	float* db = *b;
	if (!db)
		cudaMalloc(&db, sizeof(float) * out_rows * out_cols * ch * batch);
	*b = db;
	dim3 num_blocks(out_rows, out_cols, ch);
	dim3 threads_per_block(batch);
	int shared_memory_size = sizeof(float) * batch;
	_cog_kern_average_pool_forward_propagate
	<1>
	<<<num_blocks, threads_per_block, shared_memory_size, stream>>>
	(layer->net.pool.strides, layer->net.pool.border, layer->net.pool.size, batch,
	 a, rows, cols, ch,
	 db, out_rows, out_cols);
}

template <int input_per_thread>
__global__ void _cog_kern_average_pool_backward_propagate(const int strides, const int border, const int size, const int batch,
		float* input_grad, const int rows, const int cols, const int channels,
		float* out_grad, const int out_rows, int out_cols)
{
	// gridDim.x == rows
	// gridDim.y == cols
	// gridDim.z == channels
	assert(gridDim.x == rows);
	assert(gridDim.y == cols);
	assert(gridDim.z == channels);
	extern __shared__ float shared[];
	float* shared_grad = &shared[0];
	const int thcnt = blockDim.x;
	const int thidx = threadIdx.x;
	const int input_loads = (batch + thcnt - 1) / thcnt;
	float prod[input_per_thread];
	int i, x, y;
	#pragma unroll
	for (i = 0; i < input_per_thread; i++)
		prod[i] = 0;
	const int ycnt = (size - 1 - (blockIdx.x + border) % strides) / strides + 1;
	const int xcnt = (size - 1 - (blockIdx.y + border) % strides) / strides + 1;
	const int out_y = (blockIdx.x + border) / strides - ycnt + 1;
	const int out_x = (blockIdx.y + border) / strides - xcnt + 1;
	const int out_start_y = max(out_y, 0);
	const int out_start_x = max(out_x, 0);
	out_grad += (blockIdx.z * out_rows * out_cols + out_start_y * out_cols) * batch;
	const int out_end_y = min(out_y + ycnt, out_rows);
	const int out_end_x = min(out_x + xcnt, out_cols);
	for (y = out_start_y; y < out_end_y; y++)
	{
		for (x = out_start_x; x < out_end_x; x++)
		{
			#pragma unroll
			for (i = 0; i < input_loads; i++)
				if (i * thcnt + thidx < batch)
					shared_grad[i * thcnt + thidx] = out_grad[x * batch + i * thcnt + thidx];
			__syncthreads();
			float inv_size = 1.0 / ((min(y * strides + size - border, rows) - max(y * strides - border, 0)) * (min(x * strides + size - border, cols) - max(x * strides - border, 0)));
			#pragma unroll
			for (i = 0; i < input_per_thread; i++)
				prod[i] += shared_grad[i + threadIdx.x * input_per_thread] * inv_size;
			__syncthreads();
		}
		out_grad += out_cols * batch;
	}
	input_grad += (blockIdx.z * rows * cols + blockIdx.x * cols + blockIdx.y) * batch;
	#pragma unroll
	for (i = 0; i < input_per_thread; i++)
		input_grad[i + threadIdx.x * input_per_thread] = prod[i];
}

static void _cog_convnet_average_pool_backward_propagate(ccv_convnet_layer_t* layer, int batch, int rows, int cols, int ch, float* a, float** b, const cudaStream_t& stream)
{
	int out_rows, out_cols;
	_ccv_convnet_layer_deduce_output_format(rows, cols, layer, &out_rows, &out_cols);
	float* db = *b;
	if (!db)
		cudaMalloc(&db, sizeof(float) * rows * cols * ch * batch);
	*b = db;
	dim3 num_blocks(rows, cols, ch);
	dim3 threads_per_block(batch);
	int shared_memory_size = sizeof(float) * batch * 3;
	_cog_kern_average_pool_backward_propagate
	<1>
	<<<num_blocks, threads_per_block, shared_memory_size, stream>>>
	(layer->net.pool.strides, layer->net.pool.border, layer->net.pool.size, batch,
	 db, rows, cols, ch,
	 a, out_rows, out_cols);
}

static void _cog_convnet_full_connect_forward_propagate(ccv_convnet_layer_t* layer, int batch, int rows, int cols, int ch, float* a, float** b, float* batch_unit /* this is just 1's in device */, const cublasHandle_t& handle)
{
	int out_rows, out_cols;
	_ccv_convnet_layer_deduce_output_format(rows, cols, layer, &out_rows, &out_cols);
	out_cols = batch;
	rows = rows * cols * ch;
	cols = batch;
	ch = 1;
	float* db = *b;
	if (!db)
		cudaMalloc(&db, sizeof(float) * out_rows * batch);
	*b = db;
	float alpha = 1;
	float beta = 0;
	// make copies of bias into db's columns, note that for cublas, it is row-major matrix
	cublasSgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, batch, out_rows, 1, &alpha, batch_unit, batch, layer->bias, 1, &beta, db, batch);
	beta = 1;
	// and then do the GEMM by adding bias
	cublasSgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, batch, out_rows, rows, &alpha, a, batch, layer->w, rows, &beta, db, batch);
}

static void _cog_convnet_full_connect_backward_propagate(ccv_convnet_layer_t* layer, int batch, int rows, int cols, int ch, float* a, float* m, float** b, float* batch_unit, ccv_convnet_layer_t* update, const cublasHandle_t& handle)
{
	int out_rows, out_cols;
	_ccv_convnet_layer_deduce_output_format(rows, cols, layer, &out_rows, &out_cols);
	out_cols = batch;
	rows = rows * cols * ch;
	cols = batch;
	ch = 1;
	float* db = *b;
	if (!db)
		cudaMalloc(&db, sizeof(float) * rows * batch);
	*b = db;
	float alpha = 1;
	float beta = 0;
	// propagate bias
	cublasSgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, 1, out_rows, batch, &alpha, batch_unit, 1, a, batch, &beta, update->bias, 1);
	// propagate error
	cublasSgemm(handle, CUBLAS_OP_N, CUBLAS_OP_T, batch, rows, out_rows, &alpha, a, batch, layer->w, rows, &beta, db, batch);
	// propagate weights
	cublasSgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, rows, out_rows, batch, &alpha, m, batch, a, batch, &beta, update->w, rows);
}

// ===================================== TEST CODE ==========================================

static void _ccv_convnet_convolutional_forward_propagate(ccv_convnet_layer_t* layer, ccv_dense_matrix_t* a, ccv_dense_matrix_t* d, ccv_dense_matrix_t** b)
{
	int rows, cols;
	_ccv_convnet_layer_deduce_output_format(a->rows, a->cols, layer, &rows, &cols);
	int ch = layer->net.convolutional.channels;
	int count = layer->net.convolutional.count;
	int strides = layer->net.convolutional.strides;
	int border = layer->net.convolutional.border;
	int kernel_rows = layer->net.convolutional.rows;
	int kernel_cols = layer->net.convolutional.cols;
	int type = CCV_32F | count;
	assert(CCV_GET_CHANNEL(a->type) == ch);
	assert(CCV_GET_DATA_TYPE(a->type) == CCV_32F);
	ccv_dense_matrix_t* db = *b = ccv_dense_matrix_renew(*b, rows, cols, type, type, 0);
	int i, j, x, y, k;
#define for_block(act_block_setup, act_block_begin, act_block_end) \
	for (k = 0; k < count; k++) \
	{ \
		float* ap = a->data.f32; \
		float* bp = db->data.f32 + k; \
		float* layer_w = layer->w + k * kernel_rows * kernel_cols * ch; \
		float bias = layer->bias[k]; \
		act_block_setup; \
		for (i = 0; i < db->rows; i++) \
		{ \
			int comy = ccv_max(i * strides - border, 0) - (i * strides - border); \
			int maxy = kernel_rows - comy - (i * strides + kernel_rows - ccv_min(a->rows + border, i * strides + kernel_rows)); \
			comy *= ch * kernel_cols; \
			for (j = 0; j < db->cols; j++) \
			{ \
				act_block_begin; \
				float v = bias; \
				int comx = (ccv_max(j * strides - border, 0) - (j * strides - border)) * ch; \
				int maxx = kernel_cols * ch - comx - (j * strides + kernel_cols - ccv_min(a->cols + border, j * strides + kernel_cols)) * ch; \
				float* w = layer_w + comx + comy; \
				float* apz = ap + ccv_max(j * strides - border, 0) * ch; \
				/* when we have border, we simply do zero padding */ \
				for (y = 0; y < maxy; y++) \
				{ \
					for (x = 0; x < maxx; x++) \
						v += w[x] * apz[x]; \
					w += kernel_cols * ch; \
					apz += a->cols * ch; \
				} \
				bp[j * count] = ccv_max(0, v) /* ReLU */; \
				act_block_end; \
			} \
			bp += db->cols * count; \
			ap += a->cols * ch * (ccv_max((i + 1) * strides - border, 0) - ccv_max(i * strides - border, 0)); \
		} \
	}
	if (d)
	{
#define act_block_setup \
		int* dp = d->data.i32 + k;
#define act_block_begin \
		if (!*dp) \
		{
#define act_block_end \
		} else \
			bp[j * count] = 0; \
		dp += count;
		for_block(act_block_setup, act_block_begin, act_block_end);
#undef act_block_setup
#undef act_block_begin
#undef act_block_end
	} else {
		for_block(/* empty act block setup */, /* empty act block begin */, /* empty act block end */);
	}
#undef for_block
}

// compute back propagated gradient & weight update delta
static void _ccv_convnet_convolutional_backward_propagate(ccv_convnet_layer_t* layer, ccv_dense_matrix_t* a, ccv_dense_matrix_t* n, ccv_dense_matrix_t* d, ccv_dense_matrix_t* m, ccv_dense_matrix_t** b, ccv_convnet_layer_t* update_params)
{
	// a is the input gradient (for back prop), d is the dropout,
	// x is the input (for forward prop), b is the output gradient (gradient, or known as propagated error)
	// note that y (the output from forward prop) is not included because the full connect net is simple enough that we don't need it
	int rows, cols;
	_ccv_convnet_layer_deduce_output_format(m->rows, m->cols, layer, &rows, &cols);
	int ch = layer->net.convolutional.channels;
	int count = layer->net.convolutional.count;
	int strides = layer->net.convolutional.strides;
	int border = layer->net.convolutional.border;
	int kernel_rows = layer->net.convolutional.rows;
	int kernel_cols = layer->net.convolutional.cols;
	assert(a->rows == rows);
	assert(a->cols == cols);
	assert(CCV_GET_CHANNEL(a->type) == count);
	int a_rows = a->rows, a_cols = a->cols, a_ch = CCV_GET_CHANNEL(a->type);
	a->rows = rows, a->cols = cols, a->type = (a->type - a_ch) | count;
	assert(CCV_GET_CHANNEL(m->type) == ch);
	assert(CCV_GET_DATA_TYPE(m->type) == CCV_32F);
	int i, j, x, y, k;
	// update weight gradient
#define for_block_w(act_block_setup, act_block_begin, act_block_end) \
	for (k = 0; k < count; k++) \
	{ \
		float* mp = m->data.f32; \
		float* ap = a->data.f32 + k; \
		float* np = n->data.f32 + k; \
		float* update_w = update_params->w + k * kernel_rows * kernel_cols * ch; \
		float bias = 0; \
		act_block_setup; \
		for (i = 0; i < rows; i++) \
		{ \
			int comy = ccv_max(i * strides - border, 0) - (i * strides - border); \
			int maxy = kernel_rows - comy - (i * strides + kernel_rows - ccv_min(m->rows + border, i * strides + kernel_rows)); \
			comy *= ch * kernel_cols; \
			for (j = 0; j < cols; j++) \
			{ \
				act_block_begin; \
				if (np[j * count] > 0) \
				{ /* when np is bigger than 0, relu continues to update the weight, otherwise it stops */ \
					float v = ap[j * count]; \
					bias += v; \
					int comx = (ccv_max(j * strides - border, 0) - (j * strides - border)) * ch; \
					int maxx = kernel_cols * ch - comx - (j * strides + kernel_cols - ccv_min(m->cols + border, j * strides + kernel_cols)) * ch; \
					float* w = update_w + comx + comy; \
					float* mpz = mp + ccv_max(j * strides - border, 0) * ch; \
					/* when we have border, we simply do zero padding */ \
					for (y = 0; y < maxy; y++) \
					{ \
						for (x = 0; x < maxx; x++) \
							w[x] += v * mpz[x]; \
						w += kernel_cols * ch; \
						mpz += m->cols * ch; \
					} \
				} \
				act_block_end; \
			} \
			ap += a->cols * count; \
			np += n->cols * count; \
			mp += m->cols * ch * (ccv_max((i + 1) * strides - border, 0) - ccv_max(i * strides - border, 0)); \
		} \
		update_params->bias[k] += bias; \
	}
	ccv_dense_matrix_t* db = 0;
	if (b)
	{
		db = *b = ccv_dense_matrix_renew(*b, m->rows, m->cols, CCV_32F | CCV_GET_CHANNEL(m->type), CCV_32F | CCV_GET_CHANNEL(m->type), 0);
		// clear it up before propagate result
		ccv_zero(db);
	}
#define for_block_b(act_block_setup, act_block_begin, act_block_end) \
	for (k = 0; k < count; k++) \
	{ \
		float* bp = db->data.f32; \
		float* ap = a->data.f32 + k; \
		float* np = n->data.f32 + k; \
		float* layer_w = layer->w + k * kernel_rows * kernel_cols * ch; \
		act_block_setup; \
		for (i = 0; i < rows; i++) \
		{ \
			int comy = ccv_max(i * strides - border, 0) - (i * strides - border); \
			int maxy = kernel_rows - comy - (i * strides + kernel_rows - ccv_min(db->rows + border, i * strides + kernel_rows)); \
			comy *= ch * kernel_cols; \
			for (j = 0; j < cols; j++) \
			{ \
				act_block_begin; \
				if (np[j * count] > 0) \
				{ /* when np is bigger than 0, relu continues to update the weight, otherwise it stops */ \
					float v = ap[j * count]; \
					int comx = (ccv_max(j * strides - border, 0) - (j * strides - border)) * ch; \
					int maxx = kernel_cols * ch - comx - (j * strides + kernel_cols - ccv_min(db->cols + border, j * strides + kernel_cols)) * ch; \
					float* w = layer_w + comx + comy; \
					float* bpz = bp + ccv_max(j * strides - border, 0) * ch; \
					/* when we have border, we simply do zero padding */ \
					for (y = 0; y < maxy; y++) \
					{ \
						for (x = 0; x < maxx; x++) \
							bpz[x] += v * w[x]; \
						w += kernel_cols * ch; \
						bpz += db->cols * ch; \
					} \
				} \
				act_block_end; \
			} \
			ap += a->cols * count; \
			np += n->cols * count; \
			bp += db->cols * ch * (ccv_max((i + 1) * strides - border, 0) - ccv_max(i * strides - border, 0)); \
		} \
	}
	if (d)
	{
#define act_block_setup \
		int* dp = d->data.i32 + k;
#define act_block_begin \
		if (!*dp) \
		{
#define act_block_end \
		} \
		dp += count;
		for_block_w(act_block_setup, act_block_begin, act_block_end);
		if (db)
			for_block_b(act_block_setup, act_block_begin, act_block_end);
#undef act_block_setup
#undef act_block_begin
#undef act_block_end
	} else {
		for_block_w(/* empty act block setup */, /* empty act block begin */, /* empty act block end */);
		if (db)
			for_block_b(/* empty act block setup */, /* empty act block begin */, /* empty act block end */);
	}
#undef for_block_w
#undef for_block_b
	a->rows = a_rows, a->cols = a_cols, a->type = (a->type - CCV_GET_CHANNEL(a->type)) | a_ch;
}

static void _ccv_convnet_max_pool_forward_propagate(ccv_convnet_layer_t* layer, ccv_dense_matrix_t* a, ccv_dense_matrix_t** b)
{
	int rows, cols;
	_ccv_convnet_layer_deduce_output_format(a->rows, a->cols, layer, &rows, &cols);
	int size = layer->net.pool.size;
	int strides = layer->net.pool.strides;
	int border = layer->net.pool.border;
	assert(CCV_GET_DATA_TYPE(a->type) == CCV_32F);
	int ch = CCV_GET_CHANNEL(a->type);
	int type = CCV_32F | ch;
	ccv_dense_matrix_t* db = *b = ccv_dense_matrix_renew(*b, rows, cols, type, type, 0);
	int i, j, k, x, y;
	float* ap = a->data.f32;
	float* bp = db->data.f32;
	for (i = 0; i < db->rows; i++)
	{
		for (j = 0; j < db->cols; j++)
			for (k = 0; k < ch; k++)
			{
				float v = 0;
				int first = 1;
				for (y = 0; y < size; y++)
				{
					const int iy = i * strides - border + y;
					if (iy >= 0 && iy < a->rows)
						for (x = 0; x < size; x++)
						{
							const int ix = j * strides - border + x;
							if (ix >= 0 && ix < a->cols)
							{
								if (first)
								{
									v = ap[(j * strides - border + x + (y - border) * a->cols) * ch + k];
									first = 0;
								} else if (ap[(j * strides - border + x + (y - border) * a->cols) * ch + k] > v)
									v = ap[(j * strides - border + x + (y - border) * a->cols) * ch + k];
							}
						}
				}
				bp[j * ch + k] = v;
			}
		ap += a->cols * ch * strides;
		bp += db->cols * ch;
	}
}

static void _ccv_convnet_max_pool_backward_propagate(ccv_convnet_layer_t* layer, ccv_dense_matrix_t* a, ccv_dense_matrix_t* n, ccv_dense_matrix_t* m, ccv_dense_matrix_t** b)
{
	// a is the input gradient (for back prop), y is the output (from forward prop),
	// x is the input (for forward prop), b is the output gradient (gradient, or known as propagated error)
	// pooling layer doesn't need the dropout
	if (b)
	{
		assert(CCV_GET_CHANNEL(a->type) == CCV_GET_CHANNEL(n->type));
		assert(CCV_GET_CHANNEL(a->type) == CCV_GET_CHANNEL(m->type));
		int ch = CCV_GET_CHANNEL(a->type);
		ccv_dense_matrix_t* db = *b = ccv_dense_matrix_renew(*b, m->rows, m->cols, CCV_32F | ch, CCV_32F | ch, 0);
		ccv_zero(db);
		int size = layer->net.pool.size;
		int strides = layer->net.pool.strides;
		int border = layer->net.pool.border;
		int i, j, k, x, y;
		float* ap = a->data.f32;
		float* bp = db->data.f32;
		float* np = n->data.f32;
		float* mp = m->data.f32;
		for (i = 0; i < a->rows; i++)
		{
			for (j = 0; j < a->cols; j++)
				for (k = 0; k < ch; k++)
				{
					float v = np[j * ch + k];
					float u = ap[j * ch + k];
					for (y = 0; y < size; y++)
					{
						const int iy = i * strides - border + y;
						if (iy >= 0 && iy < db->rows)
							for (x = 0; x < size; x++)
							{
								const int ix = j * strides - border + x;
								if (ix >= 0 && ix < db->cols)
								{
									float mv = mp[(j * strides - border + x + (y - border) * m->cols) * ch + k];
									float delta = fabsf(mv - v) / ccv_max(ccv_max(mv, v), 1e-5);
									if (delta < 1e-5) // we cannot do direct comparison because CPU have different result comparing with GPU
										bp[(j * strides - border + x + (y - border) * db->cols) * ch + k] += u;
								}
							}
					}
				}
			ap += a->cols * ch;
			np += n->cols * ch;
			bp += db->cols * ch * strides;
			mp += m->cols * ch * strides;
		}
	}
}

static void _ccv_convnet_average_pool_forward_propagate(ccv_convnet_layer_t* layer, ccv_dense_matrix_t* a, ccv_dense_matrix_t** b)
{
	int rows, cols;
	_ccv_convnet_layer_deduce_output_format(a->rows, a->cols, layer, &rows, &cols);
	int size = layer->net.pool.size;
	int strides = layer->net.pool.strides;
	int border = layer->net.pool.border;
	assert(CCV_GET_DATA_TYPE(a->type) == CCV_32F);
	int ch = CCV_GET_CHANNEL(a->type);
	int type = CCV_32F | ch;
	ccv_dense_matrix_t* db = *b = ccv_dense_matrix_renew(*b, rows, cols, type, type, 0);
	int i, j, k, x, y;
	float* ap = a->data.f32;
	float* bp = db->data.f32;
	for (i = 0; i < db->rows; i++)
	{
		for (j = 0; j < db->cols; j++)
			for (k = 0; k < ch; k++)
			{
				float v = 0;
				int count = 0;
				for (y = 0; y < size; y++)
				{
					const int iy = i * strides - border + y;
					if (iy >= 0 && iy < a->rows)
						for (x = 0; x < size; x++)
						{
							const int ix = j * strides - border + x;
							if (ix >= 0 && ix < a->cols)
							{
								v += ap[(j * strides - border + x + (y - border) * a->cols) * ch + k];
								++count;
							}
						}
				}
				bp[j * ch + k] = v / count;
			}
		ap += a->cols * ch * strides;
		bp += db->cols * ch;
	}
}

static void _ccv_convnet_average_pool_backward_propagate(ccv_convnet_layer_t* layer, ccv_dense_matrix_t* a, ccv_dense_matrix_t* m, ccv_dense_matrix_t** b)
{
	// a is the input gradient (for back prop), y is the output (from forward prop),
	// x is the input (for forward prop), b is the output gradient (gradient, or known as propagated error)
	// pooling layer doesn't need the dropout
	if (b)
	{
		assert(CCV_GET_CHANNEL(a->type) == CCV_GET_CHANNEL(m->type));
		int ch = CCV_GET_CHANNEL(a->type);
		ccv_dense_matrix_t* db = *b = ccv_dense_matrix_renew(*b, m->rows, m->cols, CCV_32F | ch, CCV_32F | ch, 0);
		ccv_zero(db);
		int size = layer->net.pool.size;
		int strides = layer->net.pool.strides;
		int border = layer->net.pool.border;
		int i, j, k, x, y;
		float* ap = a->data.f32;
		float* bp = db->data.f32;
		for (i = 0; i < a->rows; i++)
		{
			for (j = 0; j < a->cols; j++)
				for (k = 0; k < ch; k++)
				{
					int count = 0;
					for (y = 0; y < size; y++)
					{
						const int iy = i * strides - border + y;
						if (iy >= 0 && iy < db->rows)
							for (x = 0; x < size; x++)
							{
								const int ix = j * strides - border + x;
								if (ix >= 0 && ix < db->cols)
									++count;
							}
					}
					float u = ap[j * ch + k] / count;
					for (y = 0; y < size; y++)
					{
						const int iy = i * strides - border + y;
						if (iy >= 0 && iy < db->rows)
							for (x = 0; x < size; x++)
							{
								const int ix = j * strides - border + x;
								if (ix >= 0 && ix < db->cols)
									bp[(j * strides - border + x + (y - border) * db->cols) * ch + k] += u;
							}
					}
				}
			ap += a->cols * ch;
			bp += db->cols * ch * strides;
		}
	}
}

static void _ccv_convnet_full_connect_forward_propagate(ccv_convnet_layer_t* layer, ccv_dense_matrix_t* a, ccv_dense_matrix_t* d, ccv_dense_matrix_t** b)
{
	assert(CCV_GET_DATA_TYPE(a->type) == CCV_32F);
	ccv_dense_matrix_t* db = *b = ccv_dense_matrix_renew(*b, layer->net.full_connect.count, 1, CCV_32F | CCV_C1, CCV_32F | CCV_C1, 0);
	int ch = CCV_GET_CHANNEL(a->type);
	int rows = a->rows, cols = a->cols;
	// reshape a for gemm
	assert(a->step == a->cols * CCV_GET_DATA_TYPE_SIZE(a->type) * ch);
	a->rows = rows * cols * ch, a->cols = 1, a->type = (a->type - ch) | CCV_C1;
	assert(a->rows * db->rows == layer->wnum);
	a->step = a->cols * CCV_GET_DATA_TYPE_SIZE(a->type);
	int i;
	float* bptr = db->data.f32;
	if (d)
	{
		int j;
		float* aptr = a->data.f32;
		float* wptr = layer->w;
		int* dptr = d->data.i32;
		for (i = 0; i < db->rows; i++)
		{
			if (!dptr[i])
			{
				float v = layer->bias[i];
				for (j = 0; j < a->rows; j++)
					v += aptr[j] * wptr[j];
				wptr += a->rows;
				bptr[i] = v;
			} else
				bptr[i] = 0;
		}
	} else {
		for (i = 0; i < db->rows; i++)
			bptr[i] = layer->bias[i];
		ccv_dense_matrix_t dw = ccv_dense_matrix(db->rows, a->rows, CCV_32F | CCV_C1, layer->w, 0);
		ccv_gemm(&dw, a, 1, db, 1, 0, (ccv_matrix_t**)&db, 0); // supply db as matrix C is allowed
	}
	a->rows = rows, a->cols = cols, a->type = (a->type - CCV_GET_CHANNEL(a->type)) | ch;
	a->step = a->cols * CCV_GET_DATA_TYPE_SIZE(a->type) * CCV_GET_CHANNEL(a->type);
}

static void _ccv_convnet_full_connect_backward_propagate(ccv_convnet_layer_t* layer, ccv_dense_matrix_t* a, ccv_dense_matrix_t* d, ccv_dense_matrix_t* x, ccv_dense_matrix_t** b, ccv_convnet_layer_t* update_params)
{
	// a is the input gradient (for back prop), d is the dropout,
	// x is the input (for forward prop), b is the output gradient (gradient, or known as propagated error)
	// note that y (the output from forward prop) is not included because the full connect net is simple enough that we don't need it
	ccv_dense_matrix_t* db = 0;
	if (b)
		db = *b = ccv_dense_matrix_renew(*b, x->rows, x->cols, CCV_32F | CCV_GET_CHANNEL(x->type), CCV_32F | CCV_GET_CHANNEL(x->type), 0);
	int x_rows = x->rows, x_cols = x->cols, x_ch = CCV_GET_CHANNEL(x->type);
	x->rows = x_rows * x_cols * x_ch, x->cols = 1, x->type = (x->type - x_ch) | CCV_C1;
	x->step = x->cols * CCV_GET_DATA_TYPE_SIZE(x->type);
	ccv_dense_matrix_t w = ccv_dense_matrix(a->rows, x->rows, CCV_32F | CCV_C1, update_params->w, 0);
	ccv_dense_matrix_t* dw = &w;
	if (d)
	{
		int* dptr = d->data.i32;
		float* aptr = a->data.f32;
		float* bptr = update_params->bias;
		int i, j;
		// bias gradient
		for (i = 0; i < a->rows; i++)
			if (dptr[i])
				bptr[i] += aptr[i];
		// weight gradient
		float* dwptr = update_params->w;
		for (i = 0; i < a->rows; i++)
		{
			if (dptr[i])
			{
				float* xptr = x->data.f32;
				for (j = 0; j < x->rows; j++)
					dwptr[j] += aptr[i] * xptr[j];
			}
			dwptr += x->rows;
		}
		// propagate error
		if (db)
		{
			ccv_zero(db);
			float* wptr = layer->w;
			for (i = 0; i < a->rows; i++)
			{
				if (dptr[i])
				{
					float* bptr = db->data.f32;
					for (j = 0; j < db->rows; j++)
						bptr[j] += wptr[j] * aptr[i];
				}
				wptr += x->rows;
			}
		}
	} else {
		// compute bias gradient
		ccv_dense_matrix_t bias = ccv_dense_matrix(a->rows, 1, CCV_32F | CCV_C1, update_params->bias, 0);
		ccv_dense_matrix_t* dbias = &bias;
		ccv_add(a, dbias, (ccv_matrix_t**)&dbias, 0);
		// compute weight gradient
		ccv_gemm(a, x, 1, dw, 1, CCV_B_TRANSPOSE, (ccv_matrix_t**)&dw, 0);
		w = ccv_dense_matrix(a->rows, x->rows, CCV_32F | CCV_C1, layer->w, 0);
		// propagate error
		if (db)
		{
			db->rows = x->rows, db->cols = x->cols, db->type = (db->type - x_ch) | CCV_C1;
			db->step = db->cols * CCV_GET_DATA_TYPE_SIZE(db->type);
			ccv_gemm(&w, a, 1, 0, 0, CCV_A_TRANSPOSE, (ccv_matrix_t**)&db, 0);
			db->rows = x_rows, db->cols = x_cols, db->type = (db->type - CCV_GET_CHANNEL(db->type)) | x_ch;
			db->step = db->cols * CCV_GET_DATA_TYPE_SIZE(db->type) * CCV_GET_CHANNEL(db->type);
		}
	}
	x->rows = x_rows, x->cols = x_cols, x->type = (x->type - CCV_GET_CHANNEL(x->type)) | x_ch;
	x->step = x->cols * CCV_GET_DATA_TYPE_SIZE(x->type) * CCV_GET_CHANNEL(x->type);
}

#include <sys/time.h>
#include <ctype.h>

static unsigned int get_current_time(void)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

void cog_convnet_encode(ccv_convnet_t* convnet, ccv_dense_matrix_t** a, ccv_dense_matrix_t** b, int batch)
{
	int ch = CCV_GET_CHANNEL(a[0]->type);
	int rows = a[0]->rows, cols = a[0]->cols;
	float* vec = 0;
	cudaMallocHost(&vec, sizeof(float) * batch * rows * cols * ch);
	int i, j, k, c, z;
	for (i = 0; i < batch; i++)
		for (k = 0; k < ch; k++)
			for (j = 0; j < rows * cols; j++)
				vec[i + (k * rows * cols + j) * batch] = a[i]->data.f32[j * ch + k];
	float* od_vec = 0;
	cudaMalloc(&od_vec, sizeof(float) * batch * rows * cols * ch);
	int out_rows, out_cols;
	_ccv_convnet_layer_deduce_output_format(rows, cols, convnet->layers, &out_rows, &out_cols);
	cudaMemcpy(od_vec, vec, sizeof(float) * batch * rows * cols * ch, cudaMemcpyHostToDevice);
	float* od_out = 0;
	cudaStream_t streams[2];
	for (i = 0; i < 2; i++)
		cudaStreamCreate(&streams[i]);

	// convolutional forward propagate
	unsigned int elapsed_time = get_current_time();
	_cog_convolutional_forward_propagate(GPU(convnet)->layers, batch, rows, cols, ch, od_vec, &od_out, streams[0]);
	cudaDeviceSynchronize();
	elapsed_time = get_current_time() - elapsed_time;
	printf("cuda elapsed time convolutional forward propagate: %u\n", elapsed_time);
	float* out = 0;
	cudaMallocHost(&out, sizeof(float) * out_rows * out_cols * convnet->layers->net.convolutional.count * batch);
	assert(out);
	cudaMemcpy(out, od_out, sizeof(float) * out_rows * out_cols * convnet->layers->net.convolutional.count * batch, cudaMemcpyDeviceToHost);

	// max pool forward propagate
	float* od_max = 0;
	elapsed_time = get_current_time();
	_cog_convnet_max_pool_forward_propagate(GPU(convnet)->layers + 1, batch, out_rows, out_cols, convnet->layers->net.convolutional.count, od_out, &od_max, streams[0]);
	cudaDeviceSynchronize();
	elapsed_time = get_current_time() - elapsed_time;
	printf("cuda elapsed time max pool forward propagate: %u\n", elapsed_time);
	assert(od_max);
	float* max_pooled = 0;
	int max_rows, max_cols;
	_ccv_convnet_layer_deduce_output_format(out_rows, out_cols, convnet->layers + 1, &max_rows, &max_cols);
	cudaMallocHost(&max_pooled, sizeof(float) * max_rows * max_cols * convnet->layers->net.convolutional.count * batch);
	assert(max_pooled);
	cudaMemcpy(max_pooled, od_max, sizeof(float) * max_rows * max_cols * convnet->layers->net.convolutional.count * batch, cudaMemcpyDeviceToHost);

	// average pool forward propagate
	float* od_average = 0;
	elapsed_time = get_current_time();
	_cog_convnet_average_pool_forward_propagate(GPU(convnet)->layers + 2, batch, out_rows, out_cols, convnet->layers->net.convolutional.count, od_out, &od_average, streams[0]);
	cudaDeviceSynchronize();
	elapsed_time = get_current_time() - elapsed_time;
	printf("cuda elapsed time average pool forward propagate: %u\n", elapsed_time);
	assert(od_average);
	float* average_pooled = 0;
	int average_rows, average_cols;
	_ccv_convnet_layer_deduce_output_format(out_rows, out_cols, convnet->layers + 2, &average_rows, &average_cols);
	cudaMallocHost(&average_pooled, sizeof(float) * average_rows * average_cols * convnet->layers->net.convolutional.count * batch);
	assert(average_pooled);
	cudaMemcpy(average_pooled, od_average, sizeof(float) * average_rows * average_cols * convnet->layers->net.convolutional.count * batch, cudaMemcpyDeviceToHost);

	// full connect forward propagate
	float* batch_unit = 0;
	cudaMalloc(&batch_unit, sizeof(float) * batch);
	float* host_batch_unit = 0;
	cudaMallocHost(&host_batch_unit, sizeof(float) * batch);
	for (i = 0; i < batch; i++)
		host_batch_unit[i] = 1;
	cudaMemcpy(batch_unit, host_batch_unit, sizeof(float) * batch, cudaMemcpyHostToDevice);
	cudaFreeHost(host_batch_unit);
	cublasHandle_t handle;
	cublasCreate(&handle);
	cublasSetStream(handle, streams[0]);
	float* od_full_connect = 0;
	elapsed_time = get_current_time();
	_cog_convnet_full_connect_forward_propagate(GPU(convnet)->layers + 3, batch, average_rows, average_cols, 5, od_average, &od_full_connect, batch_unit, handle);
	cudaDeviceSynchronize();
	elapsed_time = get_current_time() - elapsed_time;
	printf("cuda elapsed time full connect forward propagate: %u\n", elapsed_time);
	assert(od_full_connect);
	float* full_connected = 0;
	cudaMallocHost(&full_connected, sizeof(float) * batch * convnet->layers[3].net.full_connect.count);
	assert(full_connected);
	cudaMemcpy(full_connected, od_full_connect, sizeof(float) * batch * convnet->layers[3].net.full_connect.count, cudaMemcpyDeviceToHost);

	// convolutional backward propagate
	float* out_grad = 0;
	cudaMalloc(&out_grad, sizeof(float) * out_rows * out_cols * convnet->layers->net.convolutional.count * batch);
	cudaMemcpy(out_grad, od_out, sizeof(float) * out_rows * out_cols * convnet->layers->net.convolutional.count * batch, cudaMemcpyDeviceToDevice);
	float* input_grad = 0;
	elapsed_time = get_current_time();
	_cog_convnet_convolutional_backward_propagate(GPU(convnet)->layers, batch, rows, cols, ch, out_grad, od_out, od_vec, &input_grad, GPU(convnet)->updates, streams[0]);
	cudaDeviceSynchronize();
	elapsed_time = get_current_time() - elapsed_time;
	printf("cuda elapsed time convolutional backward propagate: %u\n", elapsed_time);
	float* out_weights = 0;
	cudaMallocHost(&out_weights, sizeof(float) * convnet->layers->wnum * 8 * out_rows);
	assert(out_weights);
	cudaMemcpy(out_weights, GPU(convnet)->updates->w, sizeof(float) * convnet->layers->wnum * 8 * out_rows, cudaMemcpyDeviceToHost);
	float* out_bias = 0;
	cudaMallocHost(&out_bias, sizeof(float) * convnet->layers->net.convolutional.count);
	assert(out_bias);
	cudaMemcpy(out_bias, GPU(convnet)->updates->bias, sizeof(float) * convnet->layers->net.convolutional.count, cudaMemcpyDeviceToHost);
	float* out_input_grad = 0;
	cudaMallocHost(&out_input_grad, sizeof(float) * rows * cols * batch * ch);
	assert(out_input_grad);
	cudaMemcpy(out_input_grad, input_grad, sizeof(float) * rows * cols * batch * ch, cudaMemcpyDeviceToHost);

	// max pool backward propagate
	float* max_pooled_grad = 0;
	cudaMalloc(&max_pooled_grad, sizeof(float) * max_rows * max_cols * convnet->layers->net.convolutional.count * batch);
	cudaMemcpy(max_pooled_grad, max_pooled, sizeof(float) * max_rows * max_cols * convnet->layers->net.convolutional.count * batch, cudaMemcpyDeviceToDevice);
	float* max_pooled_input_grad = 0;
	elapsed_time = get_current_time();
	_cog_convnet_max_pool_backward_propagate(GPU(convnet)->layers + 1, batch, out_rows, out_cols, convnet->layers->net.convolutional.count, max_pooled_grad, max_pooled, od_out, &max_pooled_input_grad, streams[0]);
	cudaDeviceSynchronize();
	elapsed_time = get_current_time() - elapsed_time;
	printf("cuda elapsed time max pool backward propagate: %u\n", elapsed_time);
	float* max_pooled_out_input_grad = 0;
	cudaMallocHost(&max_pooled_out_input_grad, sizeof(float) * out_rows * out_cols * convnet->layers->net.convolutional.count * batch);
	cudaMemcpy(max_pooled_out_input_grad, max_pooled_input_grad, sizeof(float) * out_rows * out_cols * convnet->layers->net.convolutional.count * batch, cudaMemcpyDeviceToHost);

	// average pool backward propagate
	float* average_pooled_input_grad = 0;
	elapsed_time = get_current_time();
	_cog_convnet_average_pool_backward_propagate(GPU(convnet)->layers + 1, batch, out_rows, out_cols, convnet->layers->net.convolutional.count, average_pooled, &average_pooled_input_grad, streams[0]);
	cudaDeviceSynchronize();
	elapsed_time = get_current_time() - elapsed_time;
	printf("cuda elapsed time average pool backward propagate: %u\n", elapsed_time);
	float* average_pooled_out_input_grad = 0;
	cudaMallocHost(&average_pooled_out_input_grad, sizeof(float) * out_rows * out_cols * convnet->layers->net.convolutional.count * batch);
	cudaMemcpy(average_pooled_out_input_grad, average_pooled_input_grad, sizeof(float) * out_rows * out_cols * convnet->layers->net.convolutional.count * batch, cudaMemcpyDeviceToHost);

	// full connect backward propagate
	float* full_connect_grad = 0;
	elapsed_time = get_current_time();
	_cog_convnet_full_connect_backward_propagate(GPU(convnet)->layers + 3, batch, average_rows, average_cols, 5, od_full_connect, od_average, &full_connect_grad, batch_unit, GPU(convnet)->updates + 3, handle);
	cudaDeviceSynchronize();
	elapsed_time = get_current_time() - elapsed_time;
	printf("cuda elapsed time full connect backward propagate: %u\n", elapsed_time);
	float* full_connected_grad = 0;
	cudaMallocHost(&full_connected_grad, sizeof(float) * average_rows * average_cols * 5 * batch);
	assert(full_connect_grad);
	cudaMemcpy(full_connected_grad, full_connect_grad, sizeof(float) * average_rows * average_cols * 5 * batch, cudaMemcpyDeviceToHost);
	float* out_fcbias = 0;
	cudaMallocHost(&out_fcbias, sizeof(float) * convnet->layers[3].net.full_connect.count);
	cudaMemcpy(out_fcbias, GPU(convnet)->updates[3].bias, sizeof(float) * convnet->layers[3].net.full_connect.count, cudaMemcpyDeviceToHost);
	float* out_fcw = 0;
	cudaMallocHost(&out_fcw, sizeof(float) * average_rows * average_cols * 5 * convnet->layers[3].net.full_connect.count);
	cudaMemcpy(out_fcw, GPU(convnet)->updates[3].w, sizeof(float) * average_rows * average_cols * 5 * convnet->layers[3].net.full_connect.count, cudaMemcpyDeviceToHost);

	ccv_convnet_layer_t updates;
	updates.w = (float*)ccmalloc(sizeof(float) * (convnet->layers->wnum + convnet->layers->net.convolutional.count));
	memset(updates.w, 0, sizeof(float) * (convnet->layers->wnum + convnet->layers->net.convolutional.count));
	updates.bias = updates.w + convnet->layers->wnum;
	ccv_convnet_layer_t fcupdates;
	fcupdates.w = (float*)ccmalloc(sizeof(float) * (convnet->layers[3].wnum + convnet->layers[3].net.full_connect.count));
	memset(fcupdates.w, 0, sizeof(float) * (convnet->layers[3].wnum + convnet->layers[3].net.full_connect.count));
	fcupdates.bias = fcupdates.w + convnet->layers[3].wnum;
	elapsed_time = get_current_time();
	for (i = 0; i < batch; i++)
	{
		// check convolutional forward propagate
		ccv_dense_matrix_t* b = 0;
		_ccv_convnet_convolutional_forward_propagate(convnet->layers, a[i], 0, &b);
		for (k = 0; k < convnet->layers->net.convolutional.count; k++)
			for (j = 0; j < out_rows * out_cols; j++)
			{
				float o = b->data.f32[j * convnet->layers->net.convolutional.count + k];
				float oo = out[j * batch + i + k * out_rows * out_cols * batch];
				float delta = fabsf(o - oo) / ccv_max(ccv_max(o, oo), 1);
				assert(!isnan(delta) && !isinf(delta));
				if (delta > 0.001)
					printf("forwprop: %d %d %f %f %f\n", k, j, delta, o, oo);
			}

		// check max pool forward propagate
		ccv_dense_matrix_t* c = 0;
		_ccv_convnet_max_pool_forward_propagate(convnet->layers + 1, b, &c);
		assert(CCV_GET_CHANNEL(c->type) == convnet->layers->net.convolutional.count);
		for (k = 0; k < convnet->layers->net.convolutional.count; k++)
			for (j = 0; j < max_rows * max_cols; j++)
			{
				float m = c->data.f32[j * convnet->layers->net.convolutional.count + k];
				float om = max_pooled[j * batch + i + k * max_rows * max_cols * batch];
				float delta = fabsf(m - om) / ccv_max(ccv_max(m, om), 1);
				assert(!isnan(delta) && !isinf(delta));
				if (delta > 0.001)
					printf("maxpool: %d %d %f %f %f\n", k, j, delta, m, om);
			}

		// check average pool forward propagate
		ccv_dense_matrix_t* d = 0;
		_ccv_convnet_average_pool_forward_propagate(convnet->layers + 2, b, &d);
		assert(CCV_GET_CHANNEL(d->type) == convnet->layers->net.convolutional.count);
		for (k = 0; k < convnet->layers->net.convolutional.count; k++)
			for (j = 0; j < average_rows * average_cols; j++)
			{
				float a = d->data.f32[j * convnet->layers->net.convolutional.count + k];
				float oa = average_pooled[j * batch + i + k * max_rows * max_cols * batch];
				float delta = fabsf(a - oa) / ccv_max(ccv_max(a, oa), 1);
				assert(!isnan(delta) && !isinf(delta));
				if (delta > 0.001)
					printf("avgpool: %d %d %f %f %f\n", k, j, delta, a, oa);
			}

		// check full connect forward propagate
		ccv_dense_matrix_t* g = ccv_dense_matrix_new(27, 27, CCV_32F | 5, 0, 0);
		for (k = 0; k < 5; k++)
			for (j = 0; j < average_rows * average_cols; j++)
				g->data.f32[k * average_rows * average_cols + j] = d->data.f32[j * convnet->layers->net.convolutional.count + k];
		ccv_dense_matrix_t* h = 0;
		_ccv_convnet_full_connect_forward_propagate(convnet->layers + 3, g, 0, &h);
		for (k = 0; k < convnet->layers[3].net.full_connect.count; k++)
		{
			float f = h->data.f32[k];
			float of = full_connected[k * batch + i];
			float delta = fabsf(f - of) / ccv_max(ccv_max(f, of), 1);
			assert(!isnan(delta) && !isinf(delta));
			if (delta > 0.00001)
				printf("fc: %d %f %f %f\n", k, delta, f, of);
		}

		// check convolutional backward propagate
		ccv_dense_matrix_t* backprop = 0;
		_ccv_convnet_convolutional_backward_propagate(convnet->layers, b, b, 0, a[i], &backprop, &updates);
		for (k = 0; k < ch; k++)
			for (j = 0; j < rows * cols; j++)
			{
				float g = backprop->data.f32[j * ch + k];
				float og = out_input_grad[j * batch + i + k * rows * cols * batch];
				float delta = fabsf(g - og) / ccv_max(ccv_max(g, og), 1);
				assert(!isnan(delta) && !isinf(delta));
				if (delta > 0.01)
					printf("backprop: %d %d %f %f %f\n", k, j, delta, g, og);
			}

		// check max pool backward propagate
		ccv_dense_matrix_t* e = 0;
		_ccv_convnet_max_pool_backward_propagate(convnet->layers + 1, c, c, b, &e);
		assert(e->rows == out_rows && e->cols == out_cols);
		for (k = 0; k < convnet->layers->net.convolutional.count; k++)
			for (j = 0; j < out_rows * out_cols; j++)
			{
				float m = e->data.f32[j * convnet->layers->net.convolutional.count + k];
				float om = max_pooled_out_input_grad[j * batch + i + k * out_rows * out_cols * batch];
				float delta = fabsf(m - om) / ccv_max(ccv_max(m, om), 1);
				if (delta > 0.001)
					printf("maxpool backprop: %d %d %f %f %f\n", k, j, delta, m, om);
			}

		// check average pool backward propagate
		ccv_dense_matrix_t* f = 0;
		_ccv_convnet_average_pool_backward_propagate(convnet->layers + 1, d, b, &f);
		assert(f->rows == out_rows && f->cols == out_cols);
		for (k = 0; k < convnet->layers->net.convolutional.count; k++)
			for (j = 0; j < out_rows * out_cols; j++)
			{
				float a = f->data.f32[j * convnet->layers->net.convolutional.count + k];
				float oa = average_pooled_out_input_grad[j * batch + i + k * out_rows * out_cols * batch];
				float delta = fabsf(a - oa) / ccv_max(ccv_max(a, oa), 1);
				if (delta > 0.001)
					printf("avgpool backprop: %d %d %f %f %f\n", k, j, delta, a, oa);
			}

		// check full connect backward propagate
		ccv_dense_matrix_t* p = 0;
		_ccv_convnet_full_connect_backward_propagate(convnet->layers + 3, h, 0, g, &p, &fcupdates);
		for (j = 0; j < average_rows * average_cols * 5; j++)
		{
			float f = p->data.f32[j];
			float of = full_connected_grad[j * batch + i];
			float delta = fabsf(f - of) / ccv_max(ccv_max(f, of), 1);
			if (delta > 0.00001)
				printf("fc backprop: %d %f %f %f\n", j, delta, f, of);
		}

		ccv_matrix_free(b);
		ccv_matrix_free(c);
		ccv_matrix_free(d);
		ccv_matrix_free(e);
		ccv_matrix_free(f);
		ccv_matrix_free(g);
		ccv_matrix_free(h);
		ccv_matrix_free(p);
		ccv_matrix_free(backprop);
	}
	elapsed_time = get_current_time() - elapsed_time;
	printf("cpu elapsed time of backward propagate: %u\n", elapsed_time);
	int filter_rows = convnet->layers->net.convolutional.rows;
	int filter_cols = convnet->layers->net.convolutional.cols;
	int filter_count = convnet->layers->net.convolutional.count;
	for (i = 0; i < filter_rows; i++)
		for (j = 0; j < filter_cols; j++)
			for (k = 0; k < filter_count; k++)
				for (c = 0; c < ch; c++)
				{
					float w = updates.w[(i * filter_cols + j) * ch + k * filter_cols * filter_rows * ch + c];
					float ow = out_weights[(i * filter_cols + j) * filter_count + k + c * filter_cols * filter_rows * filter_count];
					for (z = 1; z < 8 * out_rows; z++)
						ow += out_weights[z * filter_rows * filter_cols * filter_count * ch + (i * filter_cols + j) * filter_count + k + c * filter_cols * filter_rows * filter_count];
					float delta = fabsf(ow - w) / ccv_max(ccv_max(w, ow), 1);
					if (delta > 0.0001)
						printf("convw: %d,%d,%d,%d: %f, %f\n", i, j, k, c, w, ow);
				}
	for (i = 0; i < filter_count; i++)
	{
		float b = updates.bias[i];
		float ob = out_bias[i];
		float delta = fabsf(ob - b) / ccv_max(ccv_max(ob, b), 1);
		if (delta > 0.0001)
			printf("convb: %d: %f, %f\n", i, b, ob);
	}
	for (i = 0; i < average_rows * average_cols * 5 * convnet->layers[3].net.full_connect.count; i++)
	{
		float w = fcupdates.w[i];
		float ow = out_fcw[i];
		float delta = fabsf(ow - w) / ccv_max(ccv_max(w, ow), 1);
		if (delta > 0.00001)
			printf("fcw: %d: %f %f,%f\n", i, delta, w, ow);
	}
	for (i = 0; i < convnet->layers[3].net.full_connect.count; i++)
	{
		float b = fcupdates.bias[i];
		float ob = out_fcbias[i];
		float delta = fabsf(ob - b) / ccv_max(ccv_max(b, ob), 1);
		if (delta > 0.00001)
			printf("fcb: %d: %f %f,%f\n", i, delta, b, ob);
	}
}

void cog_convnet_classify(ccv_convnet_t* convnet, ccv_dense_matrix_t** a, int* labels, int batch)
{
}

void cog_convnet_supervised_train(ccv_convnet_t* convnet, ccv_array_t* categorizeds, ccv_array_t* tests, ccv_convnet_train_param_t params)
{
	assert(categorizeds->rnum >= 128);
	if (!GPU(convnet))
		_cog_convnet_reserve_on_device(convnet);
	int i;
	ccv_dense_matrix_t* a[128];
	for (i = 0; i < 128; i++)
	{
		ccv_categorized_t* categorized = (ccv_categorized_t*)ccv_array_get(categorizeds, i);
		ccv_dense_matrix_t* image = 0;
		ccv_read(categorized->file.filename, &image, CCV_IO_ANY_FILE | CCV_IO_RGB_COLOR);
		ccv_dense_matrix_t* b = 0;
		if (image->rows > 251 && image->cols > 251)
			ccv_resample(image, &b, 0, ccv_max(251, (int)(image->rows * 251.0 / image->cols + 0.5)), ccv_max(251, (int)(image->cols * 251.0 / image->rows + 0.5)), CCV_INTER_AREA);
		else if (image->rows < 251 || image->cols < 251)
			ccv_resample(image, &b, 0, ccv_max(251, (int)(image->rows * 251.0 / image->cols + 0.5)), ccv_max(251, (int)(image->cols * 251.0 / image->rows + 0.5)), CCV_INTER_CUBIC);
		else
			b = image;
		if (b != image)
			ccv_matrix_free(image);
		ccv_dense_matrix_t* c = 0;
		ccv_slice(b, (ccv_matrix_t**)&c, CCV_32F, 0, 0, 225, 225);
		int j, ch = CCV_GET_CHANNEL(c->type);
		for (j = 0; j < c->rows * c->cols * ch; j++)
			c->data.f32[j] = c->data.f32[j] / 255.0 * 2 - 1;
		a[i] = c;
		ccv_matrix_free(b);
	}
	cog_convnet_encode(convnet, a, 0, 128);
}

void cog_convnet_free(ccv_convnet_t* convnet)
{
	int i;
	ccv_convnet_layer_t* layers = GPU(convnet)->layers;
	for (i = 0; i < convnet->count; i++)
		cudaFree(layers[i].w);
	ccfree(convnet);
}
