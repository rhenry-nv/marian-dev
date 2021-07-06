/* All or part of this file was contributed by NVIDIA under license:
 *   Copyright (C) 2020 NVIDIA Corporation
 *   SPDX-License-Identifier: MIT
 */

#pragma once

#include "common/config.h"
#include "tensors/backend.h"  // note: this is one folder up
#include "tensors/gpu/cuda_helpers.h"
#include "common/logging.h"

#include <cublas_v2.h>
#include <cuda.h>
#include <curand.h>
#include <cusparse.h>

namespace marian {
namespace gpu {

// @TODO: in the future this should pobably become a fully fledged CudaInfo class with many attributes
struct CudaCompute {
  int major;
  int minor;
};

class Backend : public marian::Backend {
private:
  bool int8_{false};
  bool alpha_{false};
  bool tensorCore_{false};
  bool fused_{false};
  bool dumpMatrices_{false};
  void setCudaComputeCapability() {
    CUDA_CHECK(cudaDeviceGetAttribute(&compute_.major, cudaDevAttrComputeCapabilityMajor, (int)deviceId_.no));
    CUDA_CHECK(cudaDeviceGetAttribute(&compute_.minor, cudaDevAttrComputeCapabilityMinor, (int)deviceId_.no));
  }
  float * oneGPU;
  float * zeroGPU;

public:
  Backend(DeviceId deviceId, size_t seed) : marian::Backend(deviceId, seed) {
    setDevice();
    setCudaComputeCapability();
    float one = 1.0;
    float zero = 0.0;
    CUDA_CHECK(cudaMalloc(&oneGPU, 1*sizeof(float)));
    CUDA_CHECK(cudaMalloc(&zeroGPU, 1*sizeof(float)));
    CUDA_CHECK(cudaMemcpy(oneGPU, &one, 1*sizeof(float), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(zeroGPU, &zero, 1*sizeof(float), cudaMemcpyHostToDevice));
  }

  ~Backend() {
    setDevice();
    if(cusparseHandle_) {
      cusparseDestroy(cusparseHandle_);
      cusparseHandle_ = 0;
    }
    if(cublasHandle_) {
      cublasDestroy(cublasHandle_);
      cublasHandle_ = 0;
    }
    cudaFree(oneGPU);
    cudaFree(zeroGPU);
  }

  void setDevice() override { CUDA_CHECK(cudaSetDevice((int)deviceId_.no)); }

  void synchronize() override { CUDA_CHECK(cudaStreamSynchronize(0)); }

  cublasHandle_t getCublasHandle() {
    if(!cublasHandle_) { // lazy initialization here to avoid memory usage when unused
      setDevice();
      cublasCreate(&cublasHandle_);
      cublasSetStream(cublasHandle_, cudaStreamPerThread);
    }
    return cublasHandle_;
  }

  cusparseHandle_t getCusparseHandle() {
    if(!cusparseHandle_) { // lazy initialization here to avoid memory usage when unused
      setDevice();
      cusparseCreate(&cusparseHandle_);
      cusparseSetStream(cusparseHandle_, cudaStreamPerThread);  
    }
    return cusparseHandle_;
  }

  float * getOneGPU() {
    return oneGPU;
  }

  float * getZeroGPU() {
    return zeroGPU;
  }

  CudaCompute getCudaComputeCapability() { return compute_; }

  // for CPU, sets to use optimized code for inference.
  // for GPU, this is invalid. for gpu, isOptimized() function always returns false.
  void setInt16(bool optimize) override {
    LOG_ONCE(info, "setOptimized() not supported for GPU_{}", optimize);
  }

  bool isInt16() override {
    return false;
  }

  void setInt8(bool optimize) override {
    int8_ = optimize;
  }

  bool isInt8() override {
    return int8_;
  }

  void setShifted(bool shifted) override {
    LOG_ONCE(info, "setShifted() not supported for GPU_{}", shifted);
  }

  bool isShifted() override {
    return false;
  }

  void setShiftedAll(bool shiftedAll) override {
    LOG_ONCE(info, "setShiftedAll() not supported for GPU_{}", shiftedAll);
  }

  bool isShiftedAll() override {
    return false;
  }

  void setDumpQuantMult(bool dump) override {
    dumpMatrices_ = dump;
  }

  bool DumpQuantMult() override {
    return dumpMatrices_;
  }

  void setPrecomputedAlpha(bool alpha) override {
    alpha_ = alpha;
  }
  bool isPrecomputedAlpha() override {
    return alpha_;
  }

  void setLegacyBatchedGemm(bool legacyBatch) override {
    LOG_ONCE(info, "setLegacyBatchedGemm() not supported for GPU_{}", legacyBatch);;
  }
  bool isLegacyBatchedGemm() override {
    return false;
  }

  void setTensorCoreGemm(bool tensorCore) override {
    if (tensorCore) {
      ABORT_IF(getCudaComputeCapability().major < 7, "Compute capability {} below 7 do not support tensor cores", getCudaComputeCapability().major);
      tensorCore_ = tensorCore;
    }
  }
  bool useTensorCoreGemm() override {
    return tensorCore_;
  }

  void setFused(bool fused) override {
    fused_ = fused;
  }

  bool isFused() override {
    return fused_;
  }

private:
  cublasHandle_t cublasHandle_{0};     // make sure it's 0, so it can be initalized lazily
  cusparseHandle_t cusparseHandle_{0}; // as above
  CudaCompute compute_;
};
}  // namespace gpu
}  // namespace marian
