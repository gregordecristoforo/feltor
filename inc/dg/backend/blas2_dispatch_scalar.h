#pragma once
#include "blas1_dispatch_scalar.h"
#include "blas1_dispatch_shared.h"
#include "blas1_dispatch_vector.h"

namespace dg
{
namespace blas2
{
namespace detail
{

template< class ContainerType1, class MatrixType, class ContainerType2>
inline std::vector<int64_t> doDot_superacc( const ContainerType1& x, const MatrixType& m, const ContainerType2& y);

template< class Vector1, class Matrix, class Vector2 >
inline std::vector<int64_t> doDot_superacc( const Vector1& x, const Matrix& m, const Vector2& y, AnyScalarTag, AnyScalarTag)
{
    static_assert( std::is_convertible<get_value_type<Vector1>, double>::value, "We only support double precision dot products at the moment!");
    static_assert( std::is_convertible<get_value_type<Vector2>, double>::value, "We only support double precision dot products at the moment!");
    const get_value_type<Vector1>* x_ptr = &x;
    const get_value_type<Matrix>* m_ptr = &m;
    const get_value_type<Vector2>* y_ptr = &y;
    //since we only accumulate up to three values (multiplication and rest) reduce the size of the FPE
    std::vector<int64_t> h_superacc(exblas::BIN_COUNT);
    exblas::exdot_cpu<const get_value_type<Vector1>*, const get_value_type<Matrix>*, const get_value_type<Vector2>*, 3>( 1, x_ptr,m_ptr,y_ptr, &h_superacc[0]) ;
    return h_superacc;
}
template< class Vector1, class Matrix, class Vector2 >
inline std::vector<int64_t> doDot_superacc( const Vector1& x, const Matrix& m, const Vector2& y, AnyScalarTag, SharedVectorTag)
{
    static_assert( std::is_convertible<get_value_type<Vector1>, double>::value, "We only support double precision dot products at the moment!");
    static_assert( std::is_convertible<get_value_type<Vector2>, double>::value, "We only support double precision dot products at the moment!");
    //find out which one is the SharedVector and determine category
    using vector_type = find_if_t<dg::is_not_scalar, Vector1, Vector1, Vector2>;
    constexpr unsigned vector_idx = find_if_v<dg::is_not_scalar, Vector1, Vector1, Vector2>::value;
    using execution_policy = get_execution_policy<vector_type>;
    static_assert( all_true<
            dg::has_any_or_same_policy<Vector1, execution_policy>::value,
            dg::has_any_or_same_policy<Vector2, execution_policy>::value
            >::value,
        "All ContainerType types must have compatible execution policies (AnyPolicy or Same)!");
    auto size = std::get<vector_idx>(std::forward_as_tuple(x,y)).size();
    return dg::blas1::detail::doDot_dispatch( execution_policy(), size, get_pointer_or_scalar(x), get_pointer_or_scalar(m), get_pointer_or_scalar(y));
}
template< class Vector1, class Matrix, class Vector2>
inline std::vector<int64_t> doDot_superacc( const Vector1& x, const Matrix& m, const Vector2& y, AnyScalarTag, RecursiveVectorTag)
{
    //find out which one is the RecursiveVector and determine category
    constexpr unsigned vector_idx = find_if_v<dg::is_not_scalar, Vector1, Vector1, Vector2>::value;
    auto size = std::get<vector_idx>(std::forward_as_tuple(x,y)).size();
    std::vector<std::vector<int64_t>> acc( size);
    for( unsigned i=0; i<size; i++)
        acc[i] = doDot_superacc( get_element(x,i), m, get_element(y,i));
    for( unsigned i=1; i<size; i++)
    {
        int imin = exblas::IMIN, imax = exblas::IMAX;
        exblas::cpu::Normalize( &(acc[0][0]), imin, imax);
        imin = exblas::IMIN, imax = exblas::IMAX;
        exblas::cpu::Normalize( &(acc[i][0]), imin, imax);
        for( int k=exblas::IMIN; k<exblas::IMAX; k++)
            acc[0][k] += acc[i][k];
    }
    return acc[0];
}
//MPI version is defined in blas2_dispatch_mpi.h
} //namespace detail
} //namespace blas2
} //namespace dg
