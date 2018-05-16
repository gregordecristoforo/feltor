#ifndef _DG_MATRIX_CATEGORIES_
#define _DG_MATRIX_CATEGORIES_

namespace dg{

///@addtogroup dispatch
///@{
struct AnyMatrixTag{};
///@}


//
/**
 * @brief Indicates that the type has a member function with the same name and interface (up to the matrix itself of course)
as the
corresponding \c blas2 member function, for example
<tt> void symv( const ContainerType1&, ContainerType2& ); </tt>

These members are then implemented freely, in particular other \c blas1 and \c blas2 functions can be used
 */
struct SelfMadeMatrixTag: public AnyMatrixTag {};

/// One of cusp's matrices
struct CuspMatrixTag: public AnyMatrixTag {};
/// indicate one of our mpi matrices
struct MPIMatrixTag: public AnyMatrixTag {};
/// indicate one of our mpi matrices
struct SparseBlockMatrixTag: public AnyMatrixTag {};

}//namespace dg

#endif //_DG_MATRIX_CATEGORIES_
