#pragma once

#include <cassert>

#include "blas.h"
#include "elliptic.h"

/*!@file
 *
 * Contains Helmholtz and Maxwell operators
 */
namespace dg{

/**
 * @brief Matrix class that represents a Helmholtz-type operator
 *
 * @ingroup matrixoperators
 *
 * Unnormed discretization of \f[ (\chi+\alpha\Delta) \f]
 * where \f$ \chi\f$ is a function and \f$\alpha\f$ a scalar.
 * Can be used by the Invert class
 * @copydoc hide_geometry
 * @copydoc hide_matrix_container
 * @attention The Laplacian in this formula is positive as opposed to the negative sign in the Elliptic operator
 */
template< class Geometry, class Matrix, class container> 
struct Helmholtz
{
    /**
     * @brief Construct Helmholtz operator
     *
     * @param g The grid to use
     * @param alpha Scalar in the above formula
     * @param dir Direction of the Laplace operator
     * @param jfactor The jfactor used in the Laplace operator (probably 1 is always the best factor but one never knows...)
     * @note The default value of \f$\chi\f$ is one
     */
    Helmholtz( const Geometry& g, double alpha = 1., direction dir = dg::forward, double jfactor=1.):
        laplaceM_(g, normed, dir, jfactor), 
        temp_(dg::evaluate(dg::one, g)),
        alpha_(alpha)
    { 
    }
    /**
     * @brief Construct Helmholtz operator
     *
     * @param g The grid to use
     * @param bcx boundary condition in x
     * @param bcy boundary contition in y
     * @param alpha Scalar in the above formula
     * @param dir Direction of the Laplace operator
     * @param jfactor The jfactor used in the Laplace operator (probably 1 is always the best factor but one never knows...)
     * @note The default value of \f$\chi\f$ is one
     */
    Helmholtz( const Geometry& g, bc bcx, bc bcy, double alpha = 1., direction dir = dg::forward, double jfactor=1.):
        laplaceM_(g, bcx,bcy,normed, dir, jfactor), 
        temp_(dg::evaluate(dg::one, g)), 
        alpha_(alpha)
    { 
    }
    /**
     * @brief apply operator
     *
     * Computes
     * \f[ y = W( 1 + \alpha\Delta) x \f] to make the matrix symmetric
     * @param x lhs (is constant up to changes in ghost cells)
     * @param y rhs contains solution
     * @note Takes care of sign in laplaceM and thus multiplies by -alpha
     */
    void symv( container& x, container& y) 
    {
        tensor::pointwiseDot( chi_, x, temp_);
        if( alpha_ != 0)
            blas2::symv( laplaceM_, x, y);

        blas1::axpby( 1., temp_, -alpha_, y);
        blas1::pointwiseDot( laplaceM_.weights(), y, y);

    }
    /**
     * @brief These are the weights that made the operator symmetric
     *
     * @return weights
     */
    const container& weights()const {return laplaceM_.weights();}
    /**
     * @brief container to use in conjugate gradient solvers
     *
     * @return container
     */
    const container& precond()const {return laplaceM_.precond();}
    /**
     * @brief Change alpha
     *
     * @return reference to alpha
     */
    double& alpha( ){  return alpha_;}
    /**
     * @brief Access alpha
     *
     * @return alpha
     */
    double alpha( ) const  {return alpha_;}
    /**
     * @brief Set Chi in the above formula
     *
     * @param chi new container
     */
    void set_chi( const container& chi) {chi_.value()=chi;}
    /**
     * @brief Sets chi back to one
     */
    void reset_chi(){chi_.clear();}
    /**
     * @brief Access chi
     *
     * @return chi
     */
    const SparseElement<container>& chi() const{return chi_;}
  private:
    Elliptic<Geometry, Matrix, container> laplaceM_;
    container temp_;
    SparseElement<container> chi_;
    double alpha_;
};

/**
 * @brief Matrix class that represents a more general Helmholtz-type operator
 *
 * @ingroup matrixoperators
 *
 * Unnormed discretization of 
 * \f[ \left[ \chi +2 \alpha\Delta +  \alpha^2\Delta \left(\chi^{-1}\Delta \right)\right] \f] 
 * where \f$ \chi\f$ is a function and \f$\alpha\f$ a scalar.
 * Can be used by the Invert class
 * @copydoc hide_geometry
 * @copydoc hide_matrix_container
 * @attention The Laplacian in this formula is positive as opposed to the negative sign in the Elliptic operator
 * @attention It might be better to solve the normal Helmholtz operator twice
 * consecutively than solving the Helmholtz2 operator once. 
 */
template< class Geometry, class Matrix, class container> 
struct Helmholtz2
{
    /**
     * @brief Construct Helmholtz operator
     *
     * @param g The grid to use
     * @param alpha Scalar in the above formula
     * @param dir Direction of the Laplace operator
     * @param jfactor The jfactor used in the Laplace operator (probably 1 is always the best factor but one never knows...)
     * @note The default value of \f$\chi\f$ is one
     */
    Helmholtz2( const Geometry& g, double alpha = 1., direction dir = dg::forward, double jfactor=1.):
        laplaceM_(g, normed, dir, jfactor), 
        temp1_(dg::evaluate(dg::one, g)),temp2_(temp1_), chi_(temp1_),
        alpha_(alpha)
    { 
    }
    /**
     * @brief Construct Helmholtz operator
     *
     * @param g The grid to use
     * @param bcx boundary condition in x
     * @param bcy boundary contition in y
     * @param alpha Scalar in the above formula
     * @param dir Direction of the Laplace operator
     * @param jfactor The jfactor used in the Laplace operator (probably 1 is always the best factor but one never knows...)
     * @note The default value of \f$\chi\f$ is one
     */
    Helmholtz2( const Geometry& g, bc bcx, bc bcy, double alpha = 1., direction dir = dg::forward, double jfactor=1.):
        laplaceM_(g, bcx,bcy,normed, dir, jfactor), 
        temp1_(dg::evaluate(dg::one, g)), temp2_(temp1_),chi_(temp1_),
        alpha_(alpha)
    { 
    }
    /**
     * @brief apply operator
     *
     * Computes
     * \f[ y = W\left[ \chi +2 \alpha\Delta +  \alpha^2\Delta \left(\chi^{-1}\Delta \right)\right] x \f] to make the matrix symmetric
     * @param x lhs (is constant up to changes in ghost cells)
     * @param y rhs contains solution
     * @note Takes care of sign in laplaceM and thus multiplies by -alpha
     */
    void symv( container& x, container& y) 
    {
        if( alpha_ != 0)
        {
            blas2::symv( laplaceM_, x, temp1_); // temp1_ = -nabla_perp^2 x
            tensor::pointwiseDivide(temp1_, chi_, y); //temp2_ = (chi^-1)*W*nabla_perp^2 x
            blas2::symv( laplaceM_, y, temp2_);//temp2_ = nabla_perp^2 *(chi^-1)*nabla_perp^2 x            
        }
        tensor::pointwiseDot( chi_, x, y); //y = chi*x
        blas1::axpby( 1., y, -2.*alpha_, temp1_, y); 
        blas1::axpby( alpha_*alpha_, temp2_, 1., y, y);
        blas1::pointwiseDot( laplaceM_.weights(), y, y);//Helmholtz is never normed
    }
    /**
     * @brief These are the weights that made the operator symmetric
     *
     * @return weights
     */
    const container& weights()const {return laplaceM_.weights();}
    /**
     * @brief container to use in conjugate gradient solvers
     *
     * multiply result by these coefficients to get the normed result
     * @return container
     */
    const container& precond()const {return laplaceM_.precond();}
    /**
     * @brief Change alpha
     *
     * @return reference to alpha
     */
    double& alpha( ){  return alpha_;}
    /**
     * @brief Access alpha
     *
     * @return alpha
     */
    double alpha( ) const  {return alpha_;}
    /**
     * @brief Set Chi in the above formula
     *
     * @param chi new container
     */
    void set_chi( const container& chi) {chi_.value()=chi; }
    /**
     * @brief Sets chi back to one
     */
    void reset_chi(){chi_.clear();}
    /**
     * @brief Access chi
     *
     * @return chi
     */
    const SparseElement<container>& chi()const {return chi_;}
  private:
    Elliptic<Geometry, Matrix, container> laplaceM_;
    container temp1_, temp2_;
    SparseElement<container> chi_;
    double alpha_;
};
///@cond
template< class G, class M, class V>
struct MatrixTraits< Helmholtz<G, M, V> >
{
    typedef double value_type;
    typedef SelfMadeMatrixTag matrix_category;
};
template< class G, class M, class V>
struct MatrixTraits< const Helmholtz<G, M, V> >
{
    typedef double value_type;
    typedef SelfMadeMatrixTag matrix_category;
};
template< class G, class M, class V>
struct MatrixTraits< Helmholtz2<G, M, V> >
{
    typedef double value_type;
    typedef SelfMadeMatrixTag matrix_category;
};
template< class G, class M, class V>
struct MatrixTraits< const Helmholtz2<G, M, V> >
{
    typedef double value_type;
    typedef SelfMadeMatrixTag matrix_category;
};
///@endcond


} //namespace dg

