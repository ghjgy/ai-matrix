#include <cstdlib>
#include <chrono>
#include <iomanip>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <tuple>
#include <vector>

#include <cuda.h>
#include <cublas_v2.h>
#include <curand.h>

#include <thrust/device_ptr.h>
#include <thrust/fill.h>

#include "tensor.h"
#define MAX(x, y) ((x>y) ? x : y)
#define VALUE 1.0f

// Define some error checking macros.
#define cudaErrCheck(stat) { cudaErrCheck_((stat), __FILE__, __LINE__); }
void cudaErrCheck_(cudaError_t stat, const char *file, int line) {
	if (stat != cudaSuccess) {
		fprintf(stderr, "CUDA Error: %s %s %d\n", cudaGetErrorString(stat), file, line);
	}
}

void correctnessCheck(int m, int n, int k, float *host ){
    for (int i = 0; i < m * n; i++) {      
        float val = host[i];
        if ( val != k *  VALUE * VALUE) {
            std::cout << "ERROR value = " << val<< std::endl;
        }
    }
}

double s_max_gflops = 0.;

int time_sgemm(Tensor<float> A, Tensor<float> B, Tensor<float> C, bool a_t, bool b_t, cublasHandle_t cublas_handle) {
    const float alpha = 1.f;
    const float beta  = 0.f;

    int m = C.dims()[0];
    int k = a_t ? A.dims()[0] : A.dims()[1];
    int n = C.dims()[1];

    int numRepeats = 50;

    // Warm up
    cublasStatus_t stat = cublasSgemm(cublas_handle,
	    a_t ? CUBLAS_OP_T : CUBLAS_OP_N,
	    b_t ? CUBLAS_OP_T : CUBLAS_OP_N,
	    m,
	    n,
	    k,
	    &alpha,
	    A.begin(), A.dims()[0],
	    B.begin(), B.dims()[0],
	    &beta,
	    C.begin(), C.dims()[0]);
    if (stat != CUBLAS_STATUS_SUCCESS) {
	throw std::runtime_error("sgemm failed");
    }

    cudaDeviceSynchronize();

    auto start = std::chrono::steady_clock::now();

    for (int i = 0; i < numRepeats; ++i) {
	cublasStatus_t stat = cublasSgemm(cublas_handle,
		a_t ? CUBLAS_OP_T : CUBLAS_OP_N,
		b_t ? CUBLAS_OP_T : CUBLAS_OP_N,
		m,
		n,
		k,
		&alpha,
		A.begin(), A.dims()[0],
		B.begin(), B.dims()[0],
		&beta,
		C.begin(), C.dims()[0]);
	if (stat != CUBLAS_STATUS_SUCCESS) {
	    throw std::runtime_error("sgemm failed");
	}
    }
    cudaDeviceSynchronize();

    auto end = std::chrono::steady_clock::now();
    

    float *c_host_cublas;
    c_host_cublas = (float*)malloc(m * n * sizeof(float));
    memset(c_host_cublas, 0 , m * n * sizeof(float));
    cudaErrCheck(cudaMemcpy(c_host_cublas, C.begin(), m * n * sizeof(float), cudaMemcpyDeviceToHost));
    correctnessCheck(m, n, k, c_host_cublas);
    
    return static_cast<int>(std::chrono::duration<double, std::micro>(end - start).count() / numRepeats);
}

double cal_gflops(int m, int n, int k, double usec)
{
    double flops = 2. * m * n * k;
    double gflops = (1E-9*flops) / (1E-6*usec);
    return gflops;
}

void gemm(int m, int n, int k, bool a_t, bool b_t, cublasHandle_t cublas_handle, curandGenerator_t curand_gen)
{
    double time, gflops;
    float flag = VALUE;
    //auto a = rand_float({m, k}, curand_gen);
    //auto b = rand_float({a_t ? m : (b_t ? n : k), b_t ? k : n}, curand_gen);
    auto a = fill({m, k}, flag);
    auto b = fill({k, n}, flag);
    auto c = fill({a_t ? k : m, n}, 0.0f);
    time = time_sgemm(a, b, c, a_t, b_t, cublas_handle);
    gflops = cal_gflops(m, n, k, time);
    s_max_gflops = MAX(gflops, s_max_gflops);
    std::cout << std::setw(15) << std::setprecision(6) << time;
    std::cout << std::setw(15) << std::setprecision(6) << gflops;
    std::cout << std::endl;
}

int main(int argc, char **argv) {
    int start = 512;
    int end = 10240;
    if (argc < 3) {
        return 0;
    }
    start = std::atoi(argv[1]);
    end = std::atoi(argv[2]);
    cudaFree(0);

    cublasHandle_t cublas_handle;
    cublasStatus_t status = cublasCreate(&cublas_handle);
    if (status != CUBLAS_STATUS_SUCCESS) {
	std::cout << "CUBLAS init failed" << std::endl;
    }

    curandGenerator_t curand_gen;

    curandCreateGenerator(&curand_gen, CURAND_RNG_PSEUDO_DEFAULT);
    curandSetPseudoRandomGeneratorSeed(curand_gen, 123ULL);

    std::vector<std::tuple<int, int, int, bool, bool>> problems;
    for (int i = start; i <= end; i = i + 1024) {
	problems.push_back(std::make_tuple(i, i, i, false, false));
    }

    std::cout << "[Time and GFLOPS Result]" << std::endl;
    std::cout << std::setfill(' ');
    std::cout << std::setw(7) << "m" << std::setw(7) << "n" << std::setw(7) << "k";
    std::cout << std::setw(7) << "a_t" << std::setw(7) << "b_t";
    std::cout << std::setw(15) << "Time (usec)" << std::setw(15) << "GFLOPS";
    std::cout << std::endl;

    for (const auto &problem : problems) {
	int m, n, k;
	bool a_t, b_t;
	std::tie(m, n, k, a_t, b_t) = problem;
	std::cout << std::setw(7) << m;
	std::cout << std::setw(7) << n;
	std::cout << std::setw(7) << k;
	std::cout << std::setw(7) << a_t ? "t" : "n";
	std::cout << std::setw(7) << b_t ? "t" : "n";	
	gemm(m, n, k, a_t, b_t, cublas_handle, curand_gen);
    }
    std::cout << "[Peak GFLOPS]" << std::endl << std::setprecision(6) << s_max_gflops << std::endl;
    cublasDestroy(cublas_handle);
    curandDestroyGenerator(curand_gen);

    return 0;
}
