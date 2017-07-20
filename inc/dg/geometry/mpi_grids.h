#pragma once

#include "geometry_traits.h"
#include "../backend/mpi_grid.h"
#include "cylindrical.h"

namespace dg
{


///@addtogroup basicgrids
///@{

/**
 * @brief The mpi version of a cartesian grid
 */
struct CartesianMPIGrid2d : public dg::MPIGrid2d
{
    typedef OrthonormalTag metric_category; 

    /**
     * @copydoc Grid2d::Grid2d()
     * @param comm a two-dimensional Cartesian communicator
     * @note the paramateres given in the constructor are global parameters 
     */
    CartesianMPIGrid2d( double x0, double x1, double y0, double y1, unsigned n, unsigned Nx, unsigned Ny, MPI_Comm comm): dg::MPIGrid2d( x0, x1, y0, y1, n, Nx, Ny, comm){}

    /**
     * @copydoc Grid2d::Grid2d()
     * @param comm a two-dimensional Cartesian communicator
     * @note the paramateres given in the constructor are global parameters 
     */
    CartesianMPIGrid2d( double x0, double x1, double y0, double y1, unsigned n, unsigned Nx, unsigned Ny, bc bcx, bc bcy, MPI_Comm comm):dg::MPIGrid2d( x0, x1, y0, y1, n, Nx, Ny,bcx, bcy, comm){}
    CartesianMPIGrid2d( const dg::MPIGrid2d& grid ):MPIGrid2d( grid){}
};

/**
 * @brief The mpi version of a cartesian grid
 */
struct CartesianMPIGrid3d : public dg::MPIGrid3d
{
    typedef OrthonormalTag metric_category; 

    /**
     * @copydoc Grid3d::Grid3d()
     * @param comm a three-dimensional Cartesian communicator
     * @note the paramateres given in the constructor are global parameters 
     */
    CartesianMPIGrid3d( double x0, double x1, double y0, double y1, double z0, double z1, unsigned n, unsigned Nx, unsigned Ny, unsigned Nz, MPI_Comm comm): dg::MPIGrid3d( x0, x1, y0, y1, z0, z1, n, Nx, Ny, Nz, comm){}

    /**
     * @copydoc Grid3d::Grid3d()
     * @param comm a three-dimensional Cartesian communicator
     * @note the paramateres given in the constructor are global parameters 
     */
    CartesianMPIGrid3d( double x0, double x1, double y0, double y1, double z0, double z1, unsigned n, unsigned Nx, unsigned Ny, unsigned Nz, bc bcx, bc bcy, bc bcz, MPI_Comm comm):dg::MPIGrid3d( x0, x1, y0, y1, z0, z1, n, Nx, Ny, Nz, bcx, bcy, bcz, comm){}
    CartesianMPIGrid3d( const dg::MPIGrid3d& grid ): dg::MPIGrid3d( grid){}
};

///@}

/**
 * @brief MPI version of Cylindrical grid
 *
 * @ingroup basicgrids
 * @tparam MPIContainer The MPI Vector container
 */
template<class MPIContainer>
struct CylindricalMPIGrid3d : public MPIGrid3d
{
    typedef typename MPIContainer::container_type LocalContainer; //!< the local container type
    typedef OrthonormalCylindricalTag metric_category; 
    typedef dg::CartesianMPIGrid2d perpendicular_grid;

    /**
     * @copydoc Grid3d::Grid3d()
     * @param comm a three-dimensional Cartesian communicator
     * @note the paramateres given in the constructor are global parameters 
     */
    CylindricalMPIGrid3d( double x0, double x1, double y0, double y1, double z0, double z1, unsigned n, unsigned Nx, unsigned Ny, unsigned Nz, MPI_Comm comm): 
        dg::MPIGrid3d( x0, x1, y0, y1, z0, z1, n, Nx, Ny, Nz, comm), 
        R_( dg::evaluate( dg::cooX3d, *this)) { }

    /**
     * @copydoc Grid3d::Grid3d()
     * @param comm a three-dimensional Cartesian communicator
     * @note the paramateres given in the constructor are global parameters 
     */
    CylindricalMPIGrid3d( double x0, double x1, double y0, double y1, double z0, double z1, unsigned n, unsigned Nx, unsigned Ny, unsigned Nz, bc bcx, bc bcy, bc bcz, MPI_Comm comm):
        dg::MPIGrid3d( x0, x1, y0, y1, z0, z1, n, Nx, Ny, Nz, bcx, bcy, bcz, comm),
        R_( dg::evaluate( dg::cooX3d, *this))
        {}

    CylindricalMPIGrid3d( const MPIGrid3d& grid ):
        MPIGrid3d( grid),
        R_( dg::evaluate( dg::cooX3d, *this))
    {}

    const MPIContainer& vol() const { return R_;}
    ///@copydoc CylindricalGrid3d::perp_grid()
    perpendicular_grid perp_grid() const { 
        MPI_Comm planeComm;
        int remain_dims[] = {true,true,false}; //true true false
        MPI_Cart_sub( communicator(), remain_dims, &planeComm);
        return dg::CartesianMPIGrid2d( global().x0(), global().x1(), global().y0(), global().y1(), global().n(), global().Nx(), global().Ny(), global().bcx(), global().bcy(), planeComm);
    }
    void set( unsigned new_n, unsigned new_Nx, unsigned new_Ny, unsigned new_Nz){
        MPIGrid3d::set(new_n,new_Ny,new_Nz);
        R_=dg::evaluate(dg::cooX3d, *this);
    }
    private:
    MPIContainer R_;
};
///@}

///@cond
/////////////////////////////////////////////////////MPI pullbacks/////////////////////////////////////////////////
namespace detail{
template< class Geometry>
MPI_Vector< thrust::host_vector<double> > doPullback( double(f)(double,double), const Geometry& g, CurvilinearTag, TwoDimensionalTag, MPITag)
{
    return doPullback<double(double,double), Geometry>( f, g);
}
template< class Geometry>
MPI_Vector< thrust::host_vector<double> > pullback( double(f)(double,double,double), const Geometry& g, CurvilinearTag, ThreeDimensionalTag, MPITag)
{
    return doPullback<double(double,double,double), Geometry>( f, g);
}

template< class BinaryOp, class Geometry>
MPI_Vector< thrust::host_vector<double> > doPullback( BinaryOp f, const Geometry& g, CurvilinearTag, TwoDimensionalTag, MPITag)
{
    thrust::host_vector<double> vec( g.size());
    for( unsigned i=0; i<g.size(); i++)
        vec[i] = f( g.r().data()[i], g.z().data()[i]);
    MPI_Vector<thrust::host_vector<double> > v( vec, g.communicator());
    return v;
}

template< class TernaryOp, class Geometry>
MPI_Vector< thrust::host_vector<double> > doPullback( TernaryOp f, const Geometry& g, CurvilinearTag, ThreeDimensionalTag, MPITag)
{
    thrust::host_vector<double> vec( g.size());
    unsigned size2d = g.n()*g.n()*g.Nx()*g.Ny();
    Grid1d gz( g.z0(), g.z1(), 1, g.Nz());
    thrust::host_vector<double> absz = create::abscissas( gz);
    for( unsigned k=0; k<g.Nz(); k++)
        for( unsigned i=0; i<size2d; i++)
            vec[k*size2d+i] = f( g.r().data()[k*size2d+i], g.z().data()[k*size2d+i], absz[k]);
    MPI_Vector<thrust::host_vector<double> > v( vec, g.communicator());
    return v;
}
template< class BinaryOp, class Geometry>
MPI_Vector< thrust::host_vector<double> > doPullback( BinaryOp f, const Geometry& g, OrthonormalCylindricalTag, TwoDimensionalTag, MPITag)
{
    return evaluate( f, g);
}
template< class TernaryOp, class Geometry>
MPI_Vector< thrust::host_vector<double> > doPullback( TernaryOp f, const Geometry& g, OrthonormalCylindricalTag, ThreeDimensionalTag, MPITag)
{
    return evaluate( f,g);
}

} //namespace detail
///@endcond

}//namespace dg
