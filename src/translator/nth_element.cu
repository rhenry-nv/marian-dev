/* All or part of this file was contributed by Intel under license:
 *   Copyright (C) 2017-2018 Intel Corporation
 *   SPDX-License-Identifier: MIT
 */

 /* All or part of this file was contributed by NVIDIA under license:
 *   Copyright (C) 2020 NVIDIA Corporation
 *   SPDX-License-Identifier: MIT
 */

#include <iostream>

#include "translator/nth_element.h"
#include "3rd_party/topk.cuh"

#include <cuda.h>
#include "tensors/gpu/cuda_helpers.h"

namespace marian {
class NthElementGPU {
public:
  NthElementGPU() = delete;
  NthElementGPU(const NthElementGPU& copy) = delete;

  NthElementGPU(size_t maxBeamSize,
                size_t maxBatchSize,
                DeviceId deviceId)
      : deviceId_(deviceId),
        maxBeamSize_(maxBeamSize), maxBatchSize_(maxBatchSize) {
    // std::cerr << "NthElement::NthElement" << std::endl;

    cudaSetDevice(deviceId_.no);

    const int tempElts = maxBatchSize * maxBeamSize * maxBeamSize * MAX_BLOCKS_PER_BEAM;
    CUDA_CHECK(cudaMalloc((void**)&topk_tmp_id_buf, tempElts * sizeof(int)));
    CUDA_CHECK(cudaMalloc((void**)&topk_tmp_val_buf, tempElts * sizeof(float)));
    CUDA_CHECK(cudaMalloc((void**)&tops, maxBatchSize * maxBeamSize * sizeof(TopK)));
    CUDA_CHECK(cudaHostAlloc((void**)&topsHost, maxBeamSize * maxBatchSize * sizeof(TopK), cudaHostAllocDefault));
  }

  ~NthElementGPU() {
    // No CUDA error checking as this is a destructor and we cannot do anything about errors anyway.
    cudaSetDevice(deviceId_.no);
    cudaFree(topk_tmp_id_buf);
    cudaFree(topk_tmp_val_buf);
    cudaFree(tops);
    cudaFreeHost(topsHost);
  }

private:
  template <typename T>
  void selectNBest(T* probs, 
                   const int batchSize,
                   const int beamsPerBatch,
                   const int beamWidth,
                   const int vocabSize) {
    cudaSetDevice(deviceId_.no);

    topK_kernelLauncher(probs, topk_tmp_id_buf, topk_tmp_val_buf, tops,
                        batchSize, beamsPerBatch, beamWidth, vocabSize, 0);    
  }

public:
  void getNBestList(Tensor scores,
                    size_t N,
                    std::vector<float>& outCosts,
                    std::vector<unsigned>& outKeys,
                    const bool isFirst) {
    cudaSetDevice(deviceId_.no);

    const auto vocabSize = scores->shape()[-1];
    const auto inputN    = scores->shape()[-2];
    const auto dimBatch  = scores->shape()[-4];

    ABORT_IF(inputN != (isFirst ? 1 : N), "Input tensor has wrong beam dim??"); // @TODO: Remove isFirst argument altogether
    ABORT_IF(vocabSize > MAX_VOCAB_SIZE, "GetNBestList(): actual vocab size {} exceeds MAX_VOCAB_SIZE of {}", vocabSize, MAX_VOCAB_SIZE);
    ABORT_IF(dimBatch > maxBatchSize_, "GetNBestList(): actual batch size {} exceeds initialization parameter {}", dimBatch, maxBatchSize_);
    ABORT_IF(std::max(N, (size_t)inputN) > maxBeamSize_, "GetNBestList(): actual beam size {} exceeds initialization parameter {}", N, maxBeamSize_);

    if(scores->type() == Type::float32) {
      selectNBest(scores->data<float>(), dimBatch, inputN, N, vocabSize);
#if COMPILE_FP16
    } else if(scores->type() == Type::float16) {
      selectNBest(scores->data<half>(), dimBatch, inputN, N, vocabSize);
#endif
    } else {
      ABORT("getNBestList not implemented for type {}", scores->type());
    }
    getPairs(dimBatch * N, outKeys, outCosts);
    ABORT_IF(outKeys.size() != dimBatch * N, "Expected {} but got {} values during topk", outKeys.size(), dimBatch * N);
  }

private:
  void getPairs(size_t numElts,
                std::vector<unsigned>& outKeys,
                std::vector<float>& outValues) {
    cudaSetDevice(deviceId_.no);
    CUDA_CHECK(cudaMemcpyAsync(topsHost,
                               tops,
                               numElts * sizeof(TopK),
                               cudaMemcpyDeviceToHost,
                               /* stream_ */ 0));

    CUDA_CHECK(cudaStreamSynchronize(/* stream_ */ 0));

    for(size_t i = 0; i < numElts; ++i) {
      outKeys.push_back(topsHost[i].p);
      outValues.push_back(topsHost[i].u);
    }
  }

  DeviceId deviceId_;

  const int MAX_VOCAB_SIZE = 500000;
  size_t maxBeamSize_;
  size_t maxBatchSize_;

  int* topk_tmp_id_buf; // [maxBatchSize * maxBeamSize, maxBeamSize * MAX_BLOCKS_PER_BEAM]
  float* topk_tmp_val_buf; // [maxBatchSize * maxBeamSize, maxBeamSize * MAX_BLOCKS_PER_BEAM]
  TopK* tops; // [maxBatchSize, maxBeamSize]
  TopK* topsHost; // [maxBatchSize, maxBeamSize]
};

// factory function
// Returns a lambda with the same signature as the getNBestList() function.
GetNBestListFn createGetNBestListGPUFn(size_t beamSize, size_t dimBatch, DeviceId deviceId) {
  auto nth = New<NthElementGPU>(beamSize, dimBatch, deviceId);
  return [nth](Tensor logProbs, size_t N, std::vector<float>& outCosts, std::vector<unsigned>& outKeys, const bool isFirst) {
    return nth->getNBestList(logProbs, N, outCosts, outKeys, isFirst);
  };
}

}  // namespace marian
