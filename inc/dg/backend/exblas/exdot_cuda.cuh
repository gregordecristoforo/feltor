/*
 * %%%%%%%%%%%%%%%%%%%%%%%Original development%%%%%%%%%%%%%%%%%%%%%%%%%
 *  Copyright (c) 2016 Inria and University Pierre and Marie Curie
 *  All rights reserved.
 * %%%%%%%%%%%%%%%%%%%%%%%Modifications and further additions%%%%%%%%%%
 *  Matthias Wiesenberger, 2017, within FELTOR and EXBLAS licenses
 */
/**
 *  @file exdot_cuda.cuh
 *  @brief CUDA version of exdot
 *
 *  @authors
 *    Developers : \n
 *        Roman Iakymchuk  -- roman.iakymchuk@lip6.fr \n
 *        Sylvain Collange -- sylvain.collange@inria.fr \n
 *        Matthias Wiesenberger -- mattwi@fysik.dtu.dk
 */
#pragma once
#include "thrust/device_vector.h"
#include "accumulate.cuh"

namespace exblas{
///@cond
namespace gpu{



////////////////////////////////////////////////////////////////////////////////
// Auxiliary functions
////////////////////////////////////////////////////////////////////////////////
__device__
static inline double TwoProductFMA(double a, double b, double *d) {
    double p = a * b;
    *d = __fma_rn(a, b, -p);
    return p;
}

__device__
static inline double KnuthTwoSum(double a, double b, double *s) {
    double r = a + b;
    double z = r - a;
    *s = (a - (r - z)) + (b - z);
    return r;
}


template<uint NBFPE, uint WARP_COUNT, class PointerOrValue1, class PointerOrValue2>
__global__ void ExDOT(
    int64_t *d_PartialSuperaccs,
    PointerOrValue1 d_a,
    PointerOrValue2 d_b,
    const uint NbElements,
    volatile bool* error
) {
    __shared__ int64_t l_sa[WARP_COUNT * BIN_COUNT]; //shared variables live for a thread block (39 rows, 16 columns!)
    int64_t *l_workingBase = l_sa + (threadIdx.x & (WARP_COUNT - 1)); //the bitwise & with 15 is a modulo operation: threadIdx.x % 16
    //Initialize superaccs
    for (uint i = 0; i < BIN_COUNT; i++)
        l_workingBase[i * WARP_COUNT] = 0;
    __syncthreads();

    //Read data from global memory and scatter it to sub-superaccs
    double a[NBFPE] = {0.0};
    for(uint pos = blockIdx.x*blockDim.x+threadIdx.x; pos < NbElements; pos += gridDim.x*blockDim.x) {
        //double r = 0.0;
        //double x = TwoProductFMA(get_element(d_a,pos), get_element(d_b,pos), &r);
        double x = d_a[pos]*d_b[pos];
        //we do not accumulate the rest of this multiplication

        //Check if the input is sane
        if( !isfinite(x) ) *error = true;

        #pragma unroll
        for(uint i = 0; i != NBFPE; ++i) {
            double s;
            a[i] = KnuthTwoSum(a[i], x, &s);
            x = s;
        }
        if (x != 0.0) {
            Accumulate(l_workingBase, x, WARP_COUNT);
            // Flush FPEs to superaccs
            #pragma unroll
            for(uint i = 0; i != NBFPE; ++i) {
                Accumulate(l_workingBase, a[i], WARP_COUNT);
                a[i] = 0.0;
            }
        }

        //if (r != 0.0) {//add the rest r in the same manner
        //    #pragma unroll
        //    for(uint i = 0; i != NBFPE; ++i) {
        //        double s;
        //        a[i] = KnuthTwoSum(a[i], r, &s);
        //        r = s;
        //    }
        //    if (r != 0.0) {
        //        Accumulate(l_workingBase, r, WARP_COUNT);
        //        // Flush FPEs to superaccs
        //        #pragma unroll
        //        for(uint i = 0; i != NBFPE; ++i) {
        //            Accumulate(l_workingBase, a[i], WARP_COUNT);
        //            a[i] = 0.0;
        //        }
        //    }
        //}
    }
    //Flush FPEs to superaccs
    #pragma unroll
    for(uint i = 0; i != NBFPE; ++i)
        Accumulate(l_workingBase, a[i], WARP_COUNT);
    __syncthreads();

    //Merge sub-superaccs into work-group partial-accumulator ( ATTENTION: PartialSuperacc is transposed!)
    uint pos = threadIdx.x;
    if(pos < WARP_COUNT) {
        int imin = IMIN, imax = IMAX;
        Normalize( l_workingBase, imin, imax, WARP_COUNT);
    }
    __syncthreads();

    if (pos < BIN_COUNT) {
        int64_t sum = 0;

        for(uint i = 0; i < WARP_COUNT; i++)
            sum += l_sa[pos * WARP_COUNT + i];

        d_PartialSuperaccs[blockIdx.x * BIN_COUNT + pos] = sum;
    }

    __syncthreads();
    if (pos == 0) {
        int imin = IMIN, imax = IMAX;
        Normalize(&d_PartialSuperaccs[blockIdx.x * BIN_COUNT], imin, imax);
    }
}

template<uint NBFPE, uint WARP_COUNT, class PointerOrValue1, class PointerOrValue2, class PointerOrValue3>
__global__ void ExDOT(
    int64_t *d_PartialSuperaccs,
    PointerOrValue1 d_a,
    PointerOrValue2 d_b,
    PointerOrValue3 d_c,
    const uint NbElements,
    volatile bool *error
) {
    __shared__ int64_t l_sa[WARP_COUNT * BIN_COUNT]; //shared variables live for a thread block (39 rows, 16 columns!)
    int64_t *l_workingBase = l_sa + (threadIdx.x & (WARP_COUNT - 1)); //the bitwise & with 15 is a modulo operation: threadIdx.x % 16
    //Initialize superaccs
    for (uint i = 0; i < BIN_COUNT; i++)
        l_workingBase[i * WARP_COUNT] = 0;
    __syncthreads();

    //Read data from global memory and scatter it to sub-superaccs
    double a[NBFPE] = {0.0};
    for(uint pos = blockIdx.x*blockDim.x+threadIdx.x; pos < NbElements; pos += gridDim.x*blockDim.x) {
        //double x2 = d_a[pos]*d_c[pos]*d_b[pos];
        //double r  = 0.0, r2 = 0.0;
        //double x  = TwoProductFMA(d_a[pos], d_b[pos], &r);
        //double x2 = TwoProductFMA(x , d_c[pos], &r2);
        double x1 = get_element(d_a,pos)*get_element(d_b,pos);
        double x2 = x1                  *get_element(d_c,pos);

        //Check if the input is sane
        if( !isfinite(x2) ) *error = true;

        if( x2 != 0.0 ) {//accumulate x2
            #pragma unroll
            for(uint i = 0; i != NBFPE; ++i) {
                double s;
                a[i] = KnuthTwoSum(a[i], x2, &s);
                x2 = s;
            }
            if (x2 != 0.0) {
                Accumulate(l_workingBase, x2, WARP_COUNT);
                // Flush FPEs to superaccs
                #pragma unroll
                for(uint i = 0; i != NBFPE; ++i) {
                    Accumulate(l_workingBase, a[i], WARP_COUNT);
                    a[i] = 0.0;
                }
            }
        }
        //if (r2 != 0.0) {//add the rest r2
        //    #pragma unroll
        //    for(uint i = 0; i != NBFPE; ++i) {
        //        double s;
        //        a[i] = KnuthTwoSum(a[i], r2, &s);
        //        r2 = s; //error was here r = s
        //    }
        //    if (r2 != 0.0) { //error was here r != 0.0
        //        Accumulate(l_workingBase, r2, WARP_COUNT);
        //        // Flush FPEs to superaccs
        //        #pragma unroll
        //        for(uint i = 0; i != NBFPE; ++i) {
        //            Accumulate(l_workingBase, a[i], WARP_COUNT);
        //            a[i] = 0.0;
        //        }
        //    }
        //}

        //if (r != 0.0) {//add the rest r*c in the same manner
        //    r2 = 0.0;
        //    x2 = TwoProductFMA(r , d_c[pos], &r2);
        //    if( x2 != 0.0) {//accumulate x2
        //        #pragma unroll
        //        for(uint i = 0; i != NBFPE; ++i) {
        //            double s;
        //            a[i] = KnuthTwoSum(a[i], x2, &s);
        //            x2 = s;
        //        }
        //        if (x2 != 0.0) {
        //            Accumulate(l_workingBase, x2, WARP_COUNT);
        //            // Flush FPEs to superaccs
        //            #pragma unroll
        //            for(uint i = 0; i != NBFPE; ++i) {
        //                Accumulate(l_workingBase, a[i], WARP_COUNT);
        //                a[i] = 0.0;
        //            }
        //        }
        //    }
        //    if (r2 != 0.0) {//add the rest r2
        //        #pragma unroll
        //        for(uint i = 0; i != NBFPE; ++i) {
        //            double s;
        //            a[i] = KnuthTwoSum(a[i], r2, &s);
        //            r2 = s; //error was here r = s
        //        }
        //        if (r2 != 0.0) { //error was here r != 0.0
        //            Accumulate(l_workingBase, r2, WARP_COUNT);
        //            // Flush FPEs to superaccs
        //            #pragma unroll
        //            for(uint i = 0; i != NBFPE; ++i) {
        //                Accumulate(l_workingBase, a[i], WARP_COUNT);
        //                a[i] = 0.0;
        //            }
        //        }
        //    }
        //}
    }
	//Flush FPEs to superaccs
    #pragma unroll
    for(uint i = 0; i != NBFPE; ++i)
        Accumulate(l_workingBase, a[i], WARP_COUNT);
    __syncthreads();

    //Merge sub-superaccs into work-group partial-accumulator ( ATTENTION: PartialSuperacc is transposed!)
    uint pos = threadIdx.x;
    if(pos<WARP_COUNT){
            int imin = IMIN, imax = IMAX;
            Normalize(l_workingBase, imin, imax, WARP_COUNT);
        }
    __syncthreads();
    if (pos < BIN_COUNT) {
        int64_t sum = 0;

        for(uint i = 0; i < WARP_COUNT; i++)
            sum += l_sa[pos * WARP_COUNT + i];

        d_PartialSuperaccs[blockIdx.x * BIN_COUNT + pos] = sum;
    }

    __syncthreads();
    if (pos == 0) {
        int imin = IMIN, imax = IMAX;
        Normalize(&d_PartialSuperaccs[blockIdx.x * BIN_COUNT], imin, imax);
    }
}

////////////////////////////////////////////////////////////////////////////////
// Merging
////////////////////////////////////////////////////////////////////////////////
////////////// parameters for Kernel execution            //////////////////////
//Kernel paramters for EXDOT
static constexpr uint WARP_COUNT               = 32; //# of sub superaccs in CUDA kernels
static constexpr uint WORKGROUP_SIZE           = 512; //# threads per block
static constexpr uint PARTIAL_SUPERACCS_COUNT  = 64; //# of blocks; each has a partial SuperAcc
//Kernel paramters for EXDOTComplete
static constexpr uint MERGE_SUPERACCS_SIZE     = 16; //# of sa each block merges; must divide PARTIAL_SUPERACCS_COUNT
static constexpr uint MERGE_WORKGROUP_SIZE     = 64;  //we need minimum 39 of those

template<uint MERGE_SIZE>
__global__
void ExDOTComplete(
     int64_t *d_PartialSuperaccs,
     int64_t *d_superacc
) {
    uint lid = threadIdx.x;
    uint gid = blockIdx.x;

    if (lid < BIN_COUNT) { //every block sums its assigned superaccs
        int64_t sum = 0;

        for(uint i = 0; i < MERGE_SIZE; i++)
            sum += d_PartialSuperaccs[(gid * MERGE_SIZE + i) * BIN_COUNT + lid];

        d_PartialSuperaccs[gid * BIN_COUNT * MERGE_SIZE + lid] = sum;
    }

    __syncthreads();
    if (lid == 0) { //every block normalize its summed superacc
        int imin = IMIN, imax = IMAX;
        Normalize(&d_PartialSuperaccs[gid * BIN_COUNT * MERGE_SIZE], imin, imax);
    }

    __syncthreads();
    if ((lid < BIN_COUNT) && (gid == 0)) {
        int64_t sum = 0;

        for(uint i = 0; i < gridDim.x; i++)
            sum += d_PartialSuperaccs[i * BIN_COUNT * MERGE_SIZE + lid];

        d_superacc[lid] = sum;
    }
}

}//namespace gpu
///@endcond

/*!@brief gpu version of exact dot product
 *
 * Computes the exact sum \f[ \sum_{i=0}^{N-1} x_i y_i \f]
 * @ingroup highlevel
 * @tparam NBFPE size of the floating point expansion (should be between 3 and 8)
 * @tparam PointerOrValue must be one of <tt> T, T&&, T&, const T&, T* or const T* </tt>, where \c T is either \c float or \c double. If it is a pointer type, then we iterate through the pointed data from 0 to \c size, else we consider the value constant in every iteration.
 * @param size size N of the arrays to sum
 * @param x1_ptr first array
 * @param x2_ptr second array
 * @param d_superacc pointer to an array of 64 bit integers (the superaccumulator) in device memory with size at least \c exblas::BIN_COUNT (39) (contents are overwritten)
 * @param status 0 indicates success, 1 indicates an input value was NaN or Inf
 * @sa \c exblas::gpu::Round to convert the superaccumulator into a double precision number
*/
template<class PointerOrValue1, class PointerOrValue2, size_t NBFPE=3>
__host__
void exdot_gpu(unsigned size, PointerOrValue1 x1_ptr, PointerOrValue2 x2_ptr, int64_t* d_superacc, int* status)
{
    static_assert( has_floating_value<PointerOrValue1>::value, "PointerOrValue1 needs to be T or T* with T one of (const) float or (const) double");
    static_assert( has_floating_value<PointerOrValue2>::value, "PointerOrValue2 needs to be T or T* with T one of (const) float or (const) double");
    static thrust::device_vector<int64_t> d_PartialSuperaccsV( gpu::PARTIAL_SUPERACCS_COUNT*BIN_COUNT, 0.0); //39 columns and PSC rows
    int64_t *d_PartialSuperaccs = thrust::raw_pointer_cast( d_PartialSuperaccsV.data());
    thrust::device_vector<bool> d_errorV(1, false);
    bool *d_error = thrust::raw_pointer_cast( d_errorV.data());
    gpu::ExDOT<NBFPE, gpu::WARP_COUNT><<<gpu::PARTIAL_SUPERACCS_COUNT, gpu::WORKGROUP_SIZE>>>( d_PartialSuperaccs, x1_ptr, x2_ptr,size, d_error);
    gpu::ExDOTComplete<gpu::MERGE_SUPERACCS_SIZE><<<gpu::PARTIAL_SUPERACCS_COUNT/gpu::MERGE_SUPERACCS_SIZE, gpu::MERGE_WORKGROUP_SIZE>>>( d_PartialSuperaccs, d_superacc );
    *status = 0;
    if( d_errorV[0] ) *status = 1;
}

/*!@brief gpu version of exact triple dot product
 *
 * Computes the exact sum \f[ \sum_{i=0}^{N-1} x_i w_i y_i \f]
 * @ingroup highlevel
 * @tparam NBFPE size of the floating point expansion (should be between 3 and 8)
 * @tparam PointerOrValue must be one of <tt> T, T&&, T&, const T&, T* or const T* </tt>, where \c T is either \c float or \c double. If it is a pointer type, then we iterate through the pointed data from 0 to \c size, else we consider the value constant in every iteration.
 * @param size size N of the arrays to sum
 * @param x1_ptr first array
 * @param x2_ptr second array
 * @param x3_ptr third array
 * @param d_superacc pointer to an array of 64 bit integegers (the superaccumulator) in device memory with size at least \c exblas::BIN_COUNT (39) (contents are overwritten)
 * @param status 0 indicates success, 1 indicates an input value was NaN or Inf
 * @sa \c exblas::gpu::Round to convert the superaccumulator into a double precision number
 */
template<class PointerOrValue1, class PointerOrValue2, class PointerOrValue3, size_t NBFPE=3>
__host__
void exdot_gpu(unsigned size, PointerOrValue1 x1_ptr, PointerOrValue2 x2_ptr, PointerOrValue3 x3_ptr, int64_t* d_superacc, int* status)
{
    static_assert( has_floating_value<PointerOrValue1>::value, "PointerOrValue1 needs to be T or T* with T one of (const) float or (const) double");
    static_assert( has_floating_value<PointerOrValue2>::value, "PointerOrValue2 needs to be T or T* with T one of (const) float or (const) double");
    static_assert( has_floating_value<PointerOrValue3>::value, "PointerOrValue3 needs to be T or T* with T one of (const) float or (const) double");
    static thrust::device_vector<int64_t> d_PartialSuperaccsV( gpu::PARTIAL_SUPERACCS_COUNT*BIN_COUNT, 0); //39 columns and PSC rows
    int64_t *d_PartialSuperaccs = thrust::raw_pointer_cast( d_PartialSuperaccsV.data());
    thrust::device_vector<bool> d_errorV(1, false);
    bool *d_error = thrust::raw_pointer_cast( d_errorV.data());
    gpu::ExDOT<NBFPE, gpu::WARP_COUNT><<<gpu::PARTIAL_SUPERACCS_COUNT, gpu::WORKGROUP_SIZE>>>( d_PartialSuperaccs, x1_ptr, x2_ptr, x3_ptr,size,d_error);
    gpu::ExDOTComplete<gpu::MERGE_SUPERACCS_SIZE><<<gpu::PARTIAL_SUPERACCS_COUNT/gpu::MERGE_SUPERACCS_SIZE, gpu::MERGE_WORKGROUP_SIZE>>>( d_PartialSuperaccs, d_superacc );
    *status = 0;
    if( d_errorV[0] ) *status = 1;
}

}//namespace exblas
