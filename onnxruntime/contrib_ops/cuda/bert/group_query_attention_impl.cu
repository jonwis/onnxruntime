/*
 The implementation of this file is based on our Multi-Head Attention impl.cu file,
 which is based on qkvToContext plugin in TensorRT demo:
 https://github.com/NVIDIA/TensorRT/tree/release/5.1/demo/BERT/

Copyright 2019 NVIDIA Corporation

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// Modifications:
// (1) support GPT-2 past state, unidirectional mask (causal)
// (2) use flash attention kernel from (https://github.com/Dao-AILab/flash-attention)
// (3) support different number of heads for Q and KV
// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include <cassert>
#include <cuda_fp16.h>
#include <cub/cub.cuh>
#include "core/providers/cuda/cu_inc/common.cuh"
#include "core/providers/cuda/cuda_common.h"
#include "core/providers/cuda/shared_inc/fpgeneric.h"
#include "contrib_ops/cuda/bert/attention_softmax.h"
#include "contrib_ops/cuda/bert/transformer_common.h"
#include "contrib_ops/cuda/bert/add_bias_transpose.h"
#include "contrib_ops/cpu/bert/attention_base.h"
#include "contrib_ops/cuda/bert/bert_padding.h"
#include "contrib_ops/cuda/utils/dump_cuda_tensor.h"
#include "contrib_ops/cuda/bert/cutlass_fmha/memory_efficient_attention.h"
#include "contrib_ops/cuda/bert/flash_attention/flash_api.h"
#include "contrib_ops/cuda/bert/group_query_attention_impl.h"
#include "contrib_ops/cuda/bert/attention_impl.h"
#include "core/providers/cuda/shared_inc/cuda_call.h"
#include "contrib_ops/cuda/bert/rotary_embedding_impl.h"
#include <cublas_v2.h>

using namespace onnxruntime::cuda;

namespace onnxruntime {
namespace contrib {
namespace cuda {

////////// Auxiliary Kernels for KV prep

// Kernel for seqlens_k
__global__ void repeat_seqlen(int32_t* seqlens_k, int32_t seqlen, int batch_size) {
  int id = blockDim.x * blockIdx.x + threadIdx.x;
  if (id < batch_size) seqlens_k[id] = seqlen;
}

// Concat new to past in present. Supports past BSNH or past BNSH
template <typename T>
Status LaunchConcatNewToPastKV(contrib::GroupQueryAttentionParameters& parameters,
                               GroupQueryAttentionData<T>& data,
                               const void* new_key,
                               const void* new_value,
                               cudaStream_t stream,
                               const int max_threads_per_block,
                               const bool past_only = false) {
  const int batch_size = parameters.batch_size;
  const int kv_sequence_length = parameters.sequence_length;
  const int past_sequence_length = parameters.seqlen_past_kv_cache;
  const int present_sequence_length = parameters.seqlen_present_kv_cache;
  const int kv_num_heads = parameters.kv_num_heads;
  const int head_size = parameters.head_size;
  const int* seqlens_k = parameters.is_first_prompt ? nullptr : reinterpret_cast<const int*>(data.seqlens_k);
  AttentionQkvFormat past_kv_format = parameters.past_kv_format;
  assert(past_kv_format == AttentionQkvFormat::Q_K_V_BSNH || past_kv_format == AttentionQkvFormat::Q_K_V_BNSH);
  const bool is_bsnh = past_kv_format == AttentionQkvFormat::Q_K_V_BSNH;

  return LaunchConcatNewToPastKV(batch_size,
                                 kv_num_heads,
                                 head_size,
                                 kv_sequence_length,
                                 past_sequence_length,
                                 present_sequence_length,
                                 is_bsnh,
                                 seqlens_k,
                                 data.past_key,
                                 data.past_value,
                                 reinterpret_cast<const T*>(new_key),
                                 reinterpret_cast<const T*>(new_value),
                                 data.present_key,
                                 data.present_value,
                                 stream,
                                 max_threads_per_block,
                                 past_only);
}

// Concat new to kv buffer in place
template <typename T>
Status LaunchConcatKVInPlace(contrib::GroupQueryAttentionParameters& parameters,
                             GroupQueryAttentionData<T>& data,
                             const void* new_key,
                             const void* new_value,
                             bool is_new_kv_bnsh_format,
                             cudaStream_t stream,
                             const int max_threads_per_block) {
  const int max_sequence_length = parameters.seqlen_present_kv_cache;
  const int* seqlens_k = (parameters.is_first_prompt && !parameters.is_subsequent_prompt) ? nullptr
                                                                                          : reinterpret_cast<const int*>(data.seqlens_k);

  assert(parameters.past_kv_format == AttentionQkvFormat::Q_K_V_BSNH ||
         parameters.past_kv_format == AttentionQkvFormat::Q_K_V_BNSH);
  bool is_past_kv_bnsh_format = (parameters.past_kv_format == AttentionQkvFormat::Q_K_V_BNSH);

  return LaunchConcatKVInPlace(parameters.batch_size,
                               parameters.kv_num_heads,
                               parameters.head_size,
                               max_sequence_length,
                               seqlens_k,
                               nullptr,  // total_seqlens_k would be wrong to use here
                               parameters.sequence_length,
                               reinterpret_cast<const T*>(new_key),
                               reinterpret_cast<const T*>(new_value),
                               data.present_key,
                               data.present_value,
                               is_past_kv_bnsh_format,
                               is_new_kv_bnsh_format,
                               stream,
                               max_threads_per_block);
}

// Kernel for use with memory efficient kernel... kv_in is grouped and of bnsh or bsnh... kv_out is ungrouped and bsnh
template <typename T>
__global__ void Ungroup(const T* kv_in,
                        T* kv_out,
                        const int in_seqlen,
                        const int kv_num_heads,
                        const bool is_bsnh) {
  const int h = threadIdx.x;
  const int out_n = threadIdx.y;
  const int s = blockIdx.x;
  const int b = blockIdx.y;

  const int out_seqlen = gridDim.x;
  const int q_num_heads = blockDim.y;
  const int H = blockDim.x;

  const int q_kv_head_ratio = q_num_heads / kv_num_heads;
  const int out_batch_stride = out_seqlen * q_num_heads * H;
  const int out_row_stride = is_bsnh ? q_num_heads * H : H;
  const int out_head_stride = is_bsnh ? H : out_seqlen * H;

  const int in_batch_stride = in_seqlen * kv_num_heads * H;
  const int in_row_stride = is_bsnh ? kv_num_heads * H : H;
  const int in_head_stride = is_bsnh ? H : in_seqlen * H;
  const int in_n = out_n / q_kv_head_ratio;

  const int out_offset = out_batch_stride * b + out_row_stride * s + out_head_stride * out_n + h;
  const int in_offset = in_batch_stride * b + in_row_stride * s + in_head_stride * in_n + h;
  kv_out[out_offset] = kv_in[in_offset];
}

template <typename T>
__global__ void UngroupLarge(const T* kv_in,
                             T* kv_out,
                             const int H,
                             const int in_seqlen,
                             const int q_num_heads,
                             const int kv_num_heads,
                             const bool is_bsnh) {
  int i = threadIdx.x + (blockDim.x * blockIdx.x);  // index along H * q_num_heads elements
  if (i < H * q_num_heads) {
    const int out_seqlen = gridDim.y;
    const int s = blockIdx.y;
    const int b = blockIdx.z;

    const int q_kv_head_ratio = q_num_heads / kv_num_heads;
    const int out_batch_stride = out_seqlen * q_num_heads * H;
    const int out_row_stride = is_bsnh ? q_num_heads * H : H;
    const int out_head_stride = is_bsnh ? H : out_seqlen * H;

    const int in_batch_stride = in_seqlen * kv_num_heads * H;
    const int in_row_stride = is_bsnh ? kv_num_heads * H : H;
    const int in_head_stride = is_bsnh ? H : in_seqlen * H;

    const int h = i % H;
    const int out_n = i / H;
    const int in_n = out_n / q_kv_head_ratio;
    const int out_offset = out_batch_stride * b + out_row_stride * s + out_head_stride * out_n + h;
    const int in_offset = in_batch_stride * b + in_row_stride * s + in_head_stride * in_n + h;
    kv_out[out_offset] = kv_in[in_offset];
  }
}

// Ungroup kv or present kv for use in Memory Efficient kernel. If present kv is not null and is BNSH, transposes it.
Status LaunchUngroup(contrib::GroupQueryAttentionParameters& parameters,
                     float2* k_buff, float2* v_buff,
                     const float2* k_og, const float2* v_og,
                     const int buff_seqlen, const int og_seqlen,
                     const bool is_bsnh,
                     cudaStream_t stream,
                     const int max_threads_per_block) {
  const int batch_size = parameters.batch_size;
  const int num_heads = parameters.num_heads;
  const int kv_num_heads = parameters.kv_num_heads;
  const int head_size = parameters.head_size;

  const int H = head_size / 4;
  if (H * num_heads <= max_threads_per_block) {
    const dim3 grid(buff_seqlen, batch_size, 1);
    const dim3 block(H, num_heads, 1);
    Ungroup<float2><<<grid, block, 0, stream>>>(k_og,
                                                k_buff,
                                                og_seqlen,
                                                kv_num_heads,
                                                is_bsnh);
    Ungroup<float2><<<grid, block, 0, stream>>>(v_og,
                                                v_buff,
                                                og_seqlen,
                                                kv_num_heads,
                                                is_bsnh);
  } else {
    int steps = int(ceil(float(H * num_heads) / 256.0));
    const dim3 grid(steps, buff_seqlen, batch_size);
    const dim3 block(256, 1, 1);
    UngroupLarge<float2><<<grid, block, 0, stream>>>(k_og,
                                                     k_buff,
                                                     H,
                                                     og_seqlen,
                                                     num_heads,
                                                     kv_num_heads,
                                                     is_bsnh);
    UngroupLarge<float2><<<grid, block, 0, stream>>>(v_og,
                                                     v_buff,
                                                     H,
                                                     og_seqlen,
                                                     num_heads,
                                                     kv_num_heads,
                                                     is_bsnh);
  }
  return CUDA_CALL(cudaGetLastError());
}

__global__ void PastToTotalSeqlen(int32_t* seqlens_k,
                                  int32_t* seqlens_k_buff,
                                  const int add_seqlen) {
  seqlens_k_buff[threadIdx.x] = seqlens_k[threadIdx.x] + add_seqlen;
}

// Calculate total sequence length from seqlens_k
Status LaunchGetSeqlensTotal(int32_t* seqlens_k, int32_t* seqlens_k_buff, const int batch_size, cudaStream_t stream,
                             const int /*threads_per_block*/) {
  const dim3 grid(1, 1, 1);
  // TODO(aciddelgado): unlikely but could have a bigger batch_size than max_threads
  const dim3 block(batch_size, 1, 1);
  PastToTotalSeqlen<<<grid, block, 0, stream>>>(seqlens_k, seqlens_k_buff, 1);
  return CUDA_CALL(cudaGetLastError());
}

// Currently, interactive decoding only works for batch_size 1
__global__ void GetSeqlensInteractive(const int32_t* seqlens_k, int32_t* seqlens_k_buff,
                                      const int batch_size, const int sequence_length) {
  int tid = blockDim.x * blockIdx.x + threadIdx.x;
  if (tid < batch_size) {
    seqlens_k_buff[tid] = seqlens_k[tid] + 1 - sequence_length;
  }
}

// Calculate past sequence length for each batch entry for flash attention kernel
Status LaunchGetSeqlensInteractive(const int32_t* seqlens_k, int32_t* seqlens_k_buff,
                                   const int batch_size, const int sequence_length, cudaStream_t stream,
                                   const int max_threads_per_block) {
  const int threads = std::min(batch_size, max_threads_per_block);
  const int blocks = (threads / max_threads_per_block) + 1;
  GetSeqlensInteractive<<<blocks, threads, 0, stream>>>(seqlens_k, seqlens_k_buff, batch_size,
                                                        sequence_length);
  return CUDA_CALL(cudaGetLastError());
}

// Kernel to unpack qkv from packed qkv
template <typename T, bool output_bnsh>
__global__ void UnpackQKV(const T* packed_qkv, T* unpacked_q, T* unpacked_k, T* unpacked_v, const int num_heads,
                          const int kv_num_heads, const int head_size, const int sequence_length,
                          const int batch_size) {
  const int tid = threadIdx.x + blockIdx.x * blockDim.x;
  int d = (num_heads + 2 * kv_num_heads) * head_size;
  const int qkv_size = batch_size * sequence_length * d;
  const int q_hidden = num_heads * head_size;
  const int k_hidden = kv_num_heads * head_size;
  if (tid < qkv_size) {
    int b = tid / (d * sequence_length);
    int s = (tid % (d * sequence_length)) / d;
    int offset = tid % d;
    if (output_bnsh) {  // output BNSH
      int head_count = kv_num_heads;
      T* unpacked;
      if (offset < q_hidden) {
        unpacked = unpacked_q;
        head_count = num_heads;
      } else if (offset < q_hidden + k_hidden) {
        unpacked = unpacked_k;
        offset -= q_hidden;
      } else {
        unpacked = unpacked_v;
        offset -= (q_hidden + k_hidden);
      }
      int n = offset / head_size;
      int h = offset % head_size;

      int unpacked_i = INDEX_4D(head_count, sequence_length, head_size, b, n, s, h);
      unpacked[unpacked_i] = packed_qkv[tid];
    } else {  // output BSNH
      if (offset < q_hidden) {
        int unpacked_i = b * sequence_length * num_heads * head_size + s * num_heads * head_size + offset;
        unpacked_q[unpacked_i] = packed_qkv[tid];
      } else if (offset < q_hidden + k_hidden) {
        int unpacked_i = b * sequence_length * kv_num_heads * head_size +
                         s * kv_num_heads * head_size + (offset - q_hidden);
        unpacked_k[unpacked_i] = packed_qkv[tid];
      } else {
        int unpacked_i = b * sequence_length * kv_num_heads * head_size +
                         s * kv_num_heads * head_size + (offset - q_hidden - k_hidden);
        unpacked_v[unpacked_i] = packed_qkv[tid];
      }
    }
  }
}

// Unpack packed qkv
template <typename T, bool output_bnsh>
Status LaunchUnpackQKV(const T* packed_qkv, T* unpacked_q, T* unpacked_k, T* unpacked_v, const int num_heads,
                       const int kv_num_heads, const int head_size, const int sequence_length, const int batch_size,
                       cudaStream_t stream, const int max_threads_per_block) {
  const int threads = max_threads_per_block;
  const int blocks = (batch_size * sequence_length * (num_heads + 2 * kv_num_heads) * head_size + threads - 1) / threads;
  UnpackQKV<T, output_bnsh><<<blocks, threads, 0, stream>>>(
      packed_qkv, unpacked_q, unpacked_k, unpacked_v, num_heads, kv_num_heads, head_size, sequence_length, batch_size);
  return CUDA_CALL(cudaGetLastError());
}

__global__ void SeqlensToPosIdsInteractive(const int32_t* seqlens_k, int64_t* position_ids,
                                           const int seqlen, const int batch_size) {
  int tid = blockDim.x * blockIdx.x + threadIdx.x;
  int b = tid / seqlen;
  int s = tid % seqlen;
  if (b < batch_size) {
    const int total_seqlen = seqlens_k[b] + 1;
    const int past_seqlen = total_seqlen - seqlen;
    if (past_seqlen + s < total_seqlen) {
      position_ids[tid] = past_seqlen + s;
    } else {
      position_ids[tid] = 1;
    }
  }
}

__global__ void SeqlensToPosIdsPrompt(const int32_t* seqlens_k, int64_t* position_ids, const int seqlen,
                                      const int batch_size) {
  int tid = blockDim.x * blockIdx.x + threadIdx.x;
  int b = tid / seqlen;
  int s = tid % seqlen;
  if (b < batch_size) {
    if (s < seqlens_k[b] + 1) {
      position_ids[tid] = s;
    } else {
      position_ids[tid] = 1;
    }
  }
}

__global__ void SeqlensToPosIdsToken(const int32_t* seqlens_k, int64_t* position_ids, const int batch_size) {
  int tid = blockDim.x * blockIdx.x + threadIdx.x;
  if (tid < batch_size) {
    position_ids[tid] = seqlens_k[tid];
  }
}

// Convert seqlens_k to position_ids
Status LaunchSeqlensToPosIds(contrib::GroupQueryAttentionParameters& parameters, const int32_t* seqlens_k,
                             int64_t* position_ids, cudaStream_t stream,
                             const int max_threads_per_block) {
  const int seqlen = parameters.sequence_length;
  const int batch_size = parameters.batch_size;
  const int threads = max_threads_per_block;
  const int blocks = (batch_size * seqlen + threads - 1) / threads;
  if (parameters.is_subsequent_prompt) {
    SeqlensToPosIdsInteractive<<<blocks, threads, 0, stream>>>(seqlens_k, position_ids, seqlen, batch_size);
  } else if (parameters.is_first_prompt) {
    SeqlensToPosIdsPrompt<<<blocks, threads, 0, stream>>>(seqlens_k, position_ids, seqlen, batch_size);
  } else {
    SeqlensToPosIdsToken<<<blocks, threads, 0, stream>>>(seqlens_k, position_ids, batch_size);
  }
  return CUDA_CALL(cudaGetLastError());
}

////////// Launch Kernels

#if USE_FLASH_ATTENTION
template <typename T>
Status FlashAttention(
    const cudaDeviceProp& device_prop,
    cudaStream_t stream,
    contrib::GroupQueryAttentionParameters& parameters,
    GroupQueryAttentionData<T>& data,
    float scale) {
  const int max_threads_per_block = device_prop.maxThreadsPerBlock;
  const int batch_size = parameters.batch_size;
  const int sequence_length = parameters.sequence_length;
  const int kv_sequence_length = parameters.sequence_length;
  const int num_heads = parameters.num_heads;
  const int kv_num_heads = parameters.kv_num_heads;
  const int head_size = parameters.head_size;
  AttentionQkvFormat past_kv_format = parameters.past_kv_format;
  bool is_causal = parameters.is_unidirectional;
  bool is_bf16 = std::is_same<T, BFloat16>::value;

  void* query = reinterpret_cast<void*>(const_cast<T*>(data.query));
  void* key;
  void* value;

  if (!parameters.is_packed_qkv) {
    key = reinterpret_cast<void*>(const_cast<T*>(data.key));
    value = reinterpret_cast<void*>(const_cast<T*>(data.value));
  } else {
    const size_t key_offset = static_cast<size_t>(num_heads * head_size);
    const size_t value_offset = static_cast<size_t>(kv_num_heads * head_size);
    key = reinterpret_cast<T*>(query) + key_offset;
    value = reinterpret_cast<T*>(key) + value_offset;
  }

  void* seqlens_k = reinterpret_cast<void*>(data.seqlens_k);
  if (parameters.is_subsequent_prompt) {
    ORT_RETURN_IF_ERROR(LaunchGetSeqlensInteractive(reinterpret_cast<const int32_t*>(data.seqlens_k),
                                                    reinterpret_cast<int32_t*>(data.seqlens_k_buff), batch_size,
                                                    sequence_length, stream, max_threads_per_block));
    seqlens_k = reinterpret_cast<void*>(data.seqlens_k_buff);
  } else if (parameters.is_first_prompt) {
    // set seqlens_k to zeros... flash api uses seqlens_k to indicate where to append key and value
    // user should use seqlens_k to index into output to get new tokens
    if (batch_size <= parameters.zeros_count) {
      seqlens_k = parameters.zero_ptr;
    } else {
      // Launch kernel to create larger seqlen tensor when batch_size > 256
      constexpr int thr_per_blk = 256;
      int blk_in_grid = (batch_size + thr_per_blk - 1) / thr_per_blk;
      repeat_seqlen<<<blk_in_grid, thr_per_blk, 0, stream>>>(data.seqlens_k_buff, 0, batch_size);
      seqlens_k = reinterpret_cast<void*>(data.seqlens_k_buff);
    }
  }

  if (!parameters.kv_share_buffer || parameters.is_first_prompt) {  // copy past kv to present kv
    ORT_RETURN_IF_ERROR(LaunchConcatNewToPastKV(parameters, data, nullptr, nullptr, stream, max_threads_per_block,
                                                true));
  }

  void* present_key = reinterpret_cast<void*>(const_cast<T*>(data.present_key));
  void* present_value = reinterpret_cast<void*>(const_cast<T*>(data.present_value));
  void* cos_cache = reinterpret_cast<void*>(const_cast<T*>(data.cos_cache));
  void* sin_cache = reinterpret_cast<void*>(const_cast<T*>(data.sin_cache));
  void* head_sink = reinterpret_cast<void*>(const_cast<T*>(data.head_sink));

  bool past_bsnh = past_kv_format == AttentionQkvFormat::Q_K_V_BSNH;

  DUMP_TENSOR_INIT();
  DUMP_TENSOR("Q", reinterpret_cast<T*>(query), batch_size, sequence_length, num_heads, head_size);
  DUMP_TENSOR("K", reinterpret_cast<T*>(present_key), batch_size, parameters.seqlen_present_kv_cache, kv_num_heads, head_size);
  DUMP_TENSOR("V", reinterpret_cast<T*>(present_value), batch_size, parameters.seqlen_present_kv_cache, kv_num_heads, head_size);

  ORT_RETURN_IF_ERROR(onnxruntime::flash::mha_fwd_kvcache(
      device_prop, stream, query, present_key, present_value, key, value, data.output,
      reinterpret_cast<void*>(data.softmax_lse), seqlens_k, cos_cache, sin_cache, head_sink, /*block_table*/ nullptr,
      batch_size, num_heads, kv_num_heads, head_size, sequence_length,
      parameters.seqlen_present_kv_cache, kv_sequence_length, parameters.rotary_dim,
      scale, parameters.softcap, is_causal, is_bf16, parameters.use_smooth_softmax, past_bsnh, parameters.num_splits,
      reinterpret_cast<void*>(data.softmax_lse_accum), reinterpret_cast<void*>(data.out_accum),
      parameters.local_window_size, parameters.rotary_interleaved, parameters.is_packed_qkv));

  // if (parameters.left_padding && parameters.is_first_prompt) {
  //   ORT_RETURN_IF_ERROR(LaunchLeftPadLast(parameters, data, stream, device_prop.maxThreadsPerBlock));
  // }

  DUMP_TENSOR("flash attention output", data.output, batch_size, sequence_length, num_heads, head_size);

  return Status::OK();
}
#endif

#if USE_MEMORY_EFFICIENT_ATTENTION
template <typename T>
Status EfficientAttention(
    const cudaDeviceProp& device_prop,
    cudaStream_t stream,
    contrib::GroupQueryAttentionParameters& parameters,
    GroupQueryAttentionData<T>& data,
    float scale) {
  const int max_threads_per_block = device_prop.maxThreadsPerBlock;
  const int batch_size = parameters.batch_size;
  const int sequence_length = parameters.sequence_length;
  const int present_sequence_length = parameters.seqlen_present_kv_cache;
  const int num_heads = parameters.num_heads;
  const int kv_num_heads = parameters.kv_num_heads;
  const int head_size = parameters.head_size;
  AttentionQkvFormat past_kv_format = parameters.past_kv_format;

  const void* query;
  const void* key;
  const void* value;

  if (!parameters.is_packed_qkv) {
    query = reinterpret_cast<const void*>(data.query);
    key = reinterpret_cast<const void*>(data.key);
    value = reinterpret_cast<const void*>(data.value);
  } else {
    size_t q_size = static_cast<size_t>(batch_size * sequence_length * num_heads * head_size);
    size_t k_size = static_cast<size_t>(batch_size * sequence_length * kv_num_heads * head_size);
    auto q = reinterpret_cast<T*>(data.unpacked_qkv_buffer);
    auto k = reinterpret_cast<T*>(data.unpacked_qkv_buffer + q_size);
    auto v = reinterpret_cast<T*>(data.unpacked_qkv_buffer + q_size + k_size);

    Status status = LaunchUnpackQKV<T, LAYOUT_BSNH>(
        reinterpret_cast<const T*>(data.query), q, k, v, num_heads, kv_num_heads,
        head_size, sequence_length, batch_size, stream, max_threads_per_block);
    if (status != Status::OK()) {
      return status;
    }

    query = reinterpret_cast<const void*>(q);
    key = reinterpret_cast<const void*>(k);
    value = reinterpret_cast<const void*>(v);
  }

  if (parameters.do_rotary) {
    size_t q_size = static_cast<size_t>(batch_size * sequence_length * num_heads * head_size);
    size_t k_size = static_cast<size_t>(batch_size * sequence_length * kv_num_heads * head_size);
    auto q_buffer = reinterpret_cast<T*>(data.rotary_buffer);
    auto k_buffer = q_buffer + q_size;
    auto position_ids_buff = reinterpret_cast<int64_t*>(k_buffer + k_size);
    ORT_RETURN_IF_ERROR(LaunchSeqlensToPosIds(parameters, data.seqlens_k, position_ids_buff, stream,
                                              max_threads_per_block));
    DUMP_TENSOR_INIT();
    DUMP_TENSOR("position_ids", position_ids_buff, batch_size, sequence_length);
    // Launch rotary embedding kernel
    ORT_RETURN_IF_ERROR(LaunchRotaryEmbeddingKernel<T>(stream, q_buffer, reinterpret_cast<const T*>(query),
                                                       position_ids_buff, data.cos_cache, data.sin_cache,
                                                       parameters.batch_size, parameters.sequence_length,
                                                       parameters.num_heads, parameters.head_size,
                                                       parameters.rotary_dim, parameters.seqlen_present_kv_cache,
                                                       /*position_ids_format*/ 1, parameters.rotary_interleaved,
                                                       device_prop.maxThreadsPerBlock, /*transposed*/ false));
    ORT_RETURN_IF_ERROR(LaunchRotaryEmbeddingKernel<T>(stream, k_buffer, reinterpret_cast<const T*>(key),
                                                       position_ids_buff, data.cos_cache, data.sin_cache,
                                                       parameters.batch_size, parameters.sequence_length,
                                                       parameters.kv_num_heads, parameters.head_size,
                                                       parameters.rotary_dim, parameters.seqlen_present_kv_cache,
                                                       /*position_ids_format*/ 1, parameters.rotary_interleaved,
                                                       device_prop.maxThreadsPerBlock, /*transposed*/ false));
    query = reinterpret_cast<const void*>(q_buffer);
    key = reinterpret_cast<const void*>(k_buffer);
  }

  if (parameters.is_subsequent_prompt || !parameters.is_first_prompt) {
    ORT_RETURN_IF_ERROR(LaunchGetSeqlensTotal(data.seqlens_k, data.seqlens_k_buff, batch_size, stream, 256));
  } else {
    // Launch kernel to copy seqlen
    constexpr int thr_per_blk = 256;
    int blk_in_grid = (batch_size + thr_per_blk - 1) / thr_per_blk;
    repeat_seqlen<<<blk_in_grid, thr_per_blk, 0, stream>>>(data.seqlens_k_buff, parameters.sequence_length,
                                                           batch_size);
  }
  int* seqlens_k = data.seqlens_k_buff;

  if (parameters.kv_share_buffer) {
    // Share buffer case
    if (data.past_key == nullptr || data.past_key != data.present_key) {
      return ORT_MAKE_STATUS(ONNXRUNTIME, INVALID_ARGUMENT,
                             "Past and present kv shall share the same tensor when kv_share_buffer is on.");
    }
    // Concatenate new kv in place
    constexpr bool is_new_kv_bnsh_format = false;
    ORT_RETURN_IF_ERROR(LaunchConcatKVInPlace(
        parameters, data, key, value, is_new_kv_bnsh_format, stream, max_threads_per_block));
  } else {
    // Not share buffer case
    if (data.past_key != nullptr && data.past_key == data.present_key) {
      return ORT_MAKE_STATUS(ONNXRUNTIME, INVALID_ARGUMENT,
                             "Past and present kv share the same tensor but kv_share_buffer is not on.");
    }
    // Copy past and concat new KV to present buffer
    ORT_RETURN_IF_ERROR(LaunchConcatNewToPastKV(parameters, data, key, value, stream, max_threads_per_block));
  }

  // Ungroup if grouped, otherwise use present kv directly
  const bool is_bsnh = past_kv_format == AttentionQkvFormat::Q_K_V_BSNH;
  if (num_heads == kv_num_heads) {
    // Use present kv directly if not grouped
    key = reinterpret_cast<const void*>(data.present_key);
    value = reinterpret_cast<const void*>(data.present_value);
  } else {
    // Otherwise we use intermediate buffers to run memory efficient attention... best avoid this path
    float2* k_buff = reinterpret_cast<float2*>(data.k);
    float2* v_buff = reinterpret_cast<float2*>(data.v);
    const float2* k_og = reinterpret_cast<const float2*>(data.present_key);
    const float2* v_og = reinterpret_cast<const float2*>(data.present_value);
    ORT_RETURN_IF_ERROR(LaunchUngroup(parameters, k_buff, v_buff, k_og, v_og, present_sequence_length,
                                      present_sequence_length, is_bsnh, stream, max_threads_per_block));
    key = reinterpret_cast<const void*>(data.k);
    value = reinterpret_cast<const void*>(data.v);
  }

  DUMP_TENSOR_INIT();
  DUMP_TENSOR("seqlens_k", seqlens_k, batch_size, 1);

  MemoryEfficientAttentionParams p;
  p.sm = device_prop.major * 10 + device_prop.minor;
  p.is_half = sizeof(T) == 2;
  p.batch_size = batch_size;
  p.num_heads = num_heads;
  p.sequence_length = sequence_length;
  p.kv_sequence_length = present_sequence_length;  // maybe remove
  p.max_sequence_length = present_sequence_length;
  p.qk_head_size = head_size;
  p.v_head_size = head_size;
  p.causal = true;
  p.scale = scale;
  p.softcap = parameters.softcap;
  p.seqlen_k_ptr = seqlens_k;  // Note: seqlens_k is total sequence length for efficient
  p.seqstart_q_ptr = nullptr;
  p.seqstart_k_ptr = nullptr;
  p.query = query;
  p.key = key;
  p.value = value;
  p.attn_bias = nullptr;
  p.is_kv_bsnh = past_kv_format == AttentionQkvFormat::Q_K_V_BSNH;
  p.output = data.output;
  p.workspace = MemoryEfficientAttentionParams::need_workspace(p.v_head_size, sizeof(T) == sizeof(float))
                    ? data.fmha_buffer
                    : nullptr;
  p.stream = stream;
  p.has_custom_right_padding = true;
  p.use_smooth_softmax = parameters.use_smooth_softmax;
  p.local_window_size = parameters.local_window_size;
  run_memory_efficient_attention(p);

  DUMP_TENSOR("efficient attention output", data.output, batch_size, sequence_length, num_heads, head_size);

  return Status::OK();
}
#endif

////////// API Functions

template <typename T>
Status QkvToContext(
    const cudaDeviceProp& device_prop,
    cublasHandle_t& /*cublas*/,
    Stream* ort_stream,
    contrib::GroupQueryAttentionParameters& parameters,
    GroupQueryAttentionData<T>& data) {
  auto stream = static_cast<cudaStream_t>(ort_stream->GetHandle());
  const float scale = parameters.scale == 0.0f ? 1.f / sqrt(static_cast<float>(parameters.head_size)) : parameters.scale;

#if USE_FLASH_ATTENTION
  if (data.use_flash_attention) {
    return FlashAttention(device_prop, stream, parameters, data, scale);
  }
#endif

#if USE_MEMORY_EFFICIENT_ATTENTION
  if (data.use_memory_efficient_attention) {
    return EfficientAttention(device_prop, stream, parameters, data, scale);
  }
#endif

  return ORT_MAKE_STATUS(ONNXRUNTIME, INVALID_ARGUMENT, "Unfused Group Query Attention not implemented yet.");
}

template struct GroupQueryAttentionData<half>;

template Status QkvToContext<half>(
    const cudaDeviceProp& device_prop,
    cublasHandle_t& cublas,
    Stream* ort_stream,
    contrib::GroupQueryAttentionParameters& parameters,
    GroupQueryAttentionData<half>& data);

template Status LaunchUnpackQKV<half, LAYOUT_BNSH>(
    const half* packed_qkv, half* unpacked_q, half* unpacked_k, half* unpacked_v, const int num_heads,
    const int kv_num_heads, const int head_size, const int sequence_length, const int batch_size,
    cudaStream_t stream, const int max_threads_per_block);

template struct GroupQueryAttentionData<BFloat16>;

template Status QkvToContext<BFloat16>(
    const cudaDeviceProp& device_prop,
    cublasHandle_t& cublas,
    Stream* ort_stream,
    contrib::GroupQueryAttentionParameters& parameters,
    GroupQueryAttentionData<BFloat16>& data);

template Status LaunchUnpackQKV<BFloat16, LAYOUT_BNSH>(
    const BFloat16* packed_qkv, BFloat16* unpacked_q, BFloat16* unpacked_k, BFloat16* unpacked_v, const int num_heads,
    const int kv_num_heads, const int head_size, const int sequence_length, const int batch_size,
    cudaStream_t stream, const int max_threads_per_block);

}  // namespace cuda
}  // namespace contrib
}  // namespace onnxruntime

#undef OFFSET_BNSH
#undef OFFSET_BSNH
