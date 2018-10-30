#pragma once

#include "dg/algorithm.h"
#include "parameters.h"
#include "geometries/geometries.h"

namespace feltor
{
//Resistivity (consistent density dependency, parallel momentum conserving, quadratic current energy conservation dependency)
struct AddResistivity{
    ddResistivity( double C, std::array<double,2> mu): m_C(C), m_mu(mu){
    }
    DG_DEVICE
    void operator()( double tilde_ne, double tilde_ni, double ue, double ui, double& dtUe, double& dtUi) const{
        double current = (tilde_ne+1)*(ui-ue);
        dtUe += -m_C/m_mu[0] * current;
        dtUi += -m_C/m_mu[1] * (tilde_ne+1)/(tilde_ni+1) * current;
    }
    private:
    double m_C;
    std::array<double,2> m_mu;
};

template<class Geometry, class IMatrix, class Matrix, class container>
struct Implicit
{

    Implicit( const Geometry& g, feltor::Parameters p,
        dg::geo::solovev::Parameters gp):
        m_p(p),
        m_gp(gp),
        m_lapM_perpN( g, p.bc["density"][0], p.bc["density"][1], dg::normed, dg::centered),
        m_lapM_perpU( g, p.bc["velocity"][0], p.bc["velocity"][1], dg::normed, dg::centered)
    {
        dg::assign( dg::evaluate( dg::zero, g), m_temp);
        //set perpendicular projection tensor h
        dg::geo::TokamakMagneticField mag = dg::geo::createSolovevField( gp);
        if( p.curvmode == "toroidal")
            mag = dg::geo::createToroidalField( gp.R_0);
        const dg::geo::BinaryVectorLvl0 bhat = dg::geo::createBHat(mag);
        dg::SparseTensor<dg::DVec> hh = dg::geo::createProjectionTensor( bhat, g3d);
        m_lapM_perpN.set_chi( hh);
        m_lapM_perpU.set_chi( hh);
    }

    void operator()( double t, const std::array<std::array<container,2>,2>& y, std::array<std::array<container,2>,2>& yp)
    {
        /* y[0][0] := N_e - 1
           y[0][1] := N_i - 1
           y[1][0] := U_e
           y[1][1] := U_i
        */
        for( unsigned i=0; i<2; i++)
        {
            //perpendicular hyperdiffusion for N and U
            dg::blas2::symv( m_lapM_perpN, y[0][i],      m_temp);
            dg::blas2::symv( -m_p.nu_perp, m_lapM_perpN, m_temp, 0., yp[0][i]);
            dg::blas2::symv( m_lapM_perpU, y[1][i],      m_temp);
            dg::blas2::symv( -m_p.nu_perp, m_lapM_perpU, m_temp, 0., yp[1][i]);
        }
    }

    const container& weights() const{
        return m_lapM_perpU.weights();
    }
    const container& inv_weights() const {
        return m_lapM_perpU.inv_weights();
    }
    const container& precond() const {
        return m_lapM_perpU.precond();
    }

  private:
    const feltor::Parameters m_p;
    const dg::geo::solovev::Parameters m_gp;
    container m_temp;
    dg::Elliptic3d<Geometry, Matrix, container> m_lapM_perpN, m_lapM_perpU;
};

struct Quantities
{
    double mass = 0, diff = 0; //mass and mass diffusion
    double energy = 0, ediff = 0; //total energy and energy diffusion
    double S[2] = {0,0}, Tpar[2] = {0,0}, Tperp = 0; //entropy parallel and perp energies
    double Dres = 0, Dpar[4] = {0,0,0,0}, Dperp[4] = {0,0,0,0}; //resisitive and diffusive terms
    double aligned = 0; //alignment parameter
};

template< class Geometry, class IMatrix, class Matrix, class container >
struct Explicit
{
    Explicit( const Geometry& g, feltor::Parameters p, dg::geo::solovev::Parameters gp);

    //potential[0]: electron potential, potential[1]: ion potential
    const std::array<container,2>& potential( ) const {
        return m_phi;
    }
    //Given N_i-1 initialize n_e-1 sucht that phi=0
    void initializene( const container& ni, container& ne);

    ///@param y y[0] := N_e - 1, y[1] := N_i - 1, y[2] := U_e, y[3] := U_i
    void operator()( double t, const std::array<std::array<container,2>,2>& y,
        std::array<std::array<container,2>,2>& yp);

    const Quantities& quantities( ) const{
        return m_q;
    }

  private:
    //extrapolates and solves for phi[1],
    //then adds square velocity ( omega)
    void compute_phi( const std::array<container,2>& densities);
    struct ComputePerpDrifts{
        ComputePerpDrifts( double mu, double tau):m_mu(mu), m_tau(tau){}
        DG_DEVICE
        void operator()(
                double tilde_N, double d0N, double d1N, double d2N,
                double U,       double d0U, double d1U, double d2U,
                double d0P, double d1P, double d2P,
                double b_0,         double b_1,         double b_2,
                double curv0,       double curv1,       double curv2,
                double curvKappa0,  double curvKappa1,  double curvKappa2,
                double divCurvKappa,
                double& dtN, double& dtU
            )
        {
            double N = tilde_N + 1.;
            double KappaU = curvKappa0*d0U+curvKappa1*d1U+curvKappa2*d2U;
            double KappaN = curvKappa0*d0N+curvKappa1*d1N+curvKappa2*d2N;
            double KappaP = curvKappa0*d0P+curvKappa1*d1P+curvKappa2*d2P;
            double KU = curv0*d0U+curv1*d1U+curv2*d2U;
            double KN = curv0*d0N+curv1*d1N+curv2*d2N;
            double KP = curv0*d0P+curv1*d1P+curv2*d2P;
            dtN =
                -b_0*( d1P*d2N-d2P*d1N)
                -b_1*( d2P*d0N-d0P*d2N)
                -b_2*( d0P*d1N-d1P*d0N) //ExB drift
                -m_tau*( KN)
                -N*(     KP)
                -m_mu*U*U* (   KappaN )
                -2.*m_mu*N*U*( KappaU )
                -m_mu*N*U*U*divCurvKappa;
            dtU =
                -b_0*( d1P*d2U-d2P*d1U)
                -b_1*( d2P*d0U-d0P*d2U)
                -b_2*( d0P*d1U-d1P*d0U)
                -U*KappaP
                -m_tau* KU
                -m_tau*U*divCurvKappa
                -(2.*m_tau + m_mu*U*U)*( KappaU )
                - 2.*m_tau*U*( KappaN )/N;
        }
        private:
        double m_mu, m_tau;
    };
    struct ComputeChi{
        DG_DEVICE
        void operator() ( double& chi, double tilde_Ni, double binv, double mu_i) const{
            chi = mu_i*(tilde_Ni+1.)*binv*binv;
        }
    };
    struct ComputePsi{
        DG_DEVICE
        void operator()( double& GammaPhi, double dxPhi, double dyPhi, double dzPhi, double& GdxPhi, double GdyPhi, double GdzPhi, double binv) const{
            //u_E^2
            GdxPhi   = (dxPhi*GdxPhi + dyPhi*GdyPhi + dzPhi*GdzPhi)*binv*binv;
            //Psi
            GammaPhi = GammaPhi - 0.5*GdxPhi;
        }
    };
    struct ComputeDiss{
        ComputeDiss( double mu, double tau):m_mu(mu), m_tau(tau){}
        DG_DEVICE
        void operator()( double& energy, double logN, double phi, double U, double mu, double tau) const{
            energy = tau*(1.+logN) + phi + 0.5*mu*U*U;
        }
        private:
        double m_mu, m_tau;
    };
    struct ComputeLogN{
        DG_DEVICE
        void operator()( double tilde_n, double& npe, double& logn) const{
            npe =  tilde_n + 1.;
            logn =  log(npe);
        }
    };
    struct ComputeSource{
        DG_DEVICE
        void operator()( double& result, double tilde_n, double profne, double source, double omega_source) const{
            double temp = omega_source*source*(profne - (tilde_n+1.));
            if ( temp > 0 )
                result = temp;
            else
                result = 0.;

        }
    };

    container m_chi, m_omega, m_lambda;//helper variables

    //these should be considered const
    std::array<container,3> m_curv, m_curvKappa, m_b;
    container m_divCurvKappa;
    container m_binv, m_gradlnB;
    container m_source, m_profne;

    std::array<container,2> m_phi, m_dxPhi, m_dyPhi, m_dzPhi, m_dsPhi;
    std::array<container,2> m_npe, m_logn, m_dxN, m_dyN, m_dzN, m_dsN,
    std::array<container,2> m_dxU, m_dyU, m_dzU, m_dsU;

    //matrices and solvers
    dg::geo::DS<Geometry, IMatrix, Matrix, container> m_ds_P, m_ds_N, m_ds_U;
    Matrix m_dx_N, m_dx_U, m_dx_P, m_dy_N, m_dy_U, m_dy_P, m_dz;
    dg::Elliptic3d<   Geometry, Matrix, container> m_lapperpN, m_lapperpP;
    std::vector<container> m_multi_chi;
    std::vector<dg::Elliptic3d< Geometry, Matrix, container> > m_multi_pol;
    std::vector<dg::Helmholtz3d<Geometry, Matrix, container> > m_multi_invgammaP,
        m_multi_invgammaN;

    dg::MultigridCG2d<Geometry, Matrix, container> m_multigrid;
    dg::Extrapolation<container> m_old_phi, m_old_psi, m_old_gammaN;

    //metric and volume elements
    container m_vol3d;
    dg::SparseTensor<container> m_metric;

    const feltor::Parameters m_p;
    const dg::geo::solovev::Parameters m_gp;
    Quantities m_q;

};
///@}

///@cond
template<class Grid, class IMatrix, class Matrix, class container>
Explicit<Grid, IMatrix, Matrix, container>::Explicit( const Grid& g, feltor::Parameters p, dg::geo::solovev::Parameters gp):
    /////////the poisson operators ////////////////////////////////////////
    m_dx_N( dg::create::dx( g, p.bc["density"][0]) ),
    m_dx_U( dg::create::dx( g, p.bc["velocity"][0]) ),
    m_dx_P( dg::create::dx( g, p.bc["potential"][0]) ),
    m_dy_N( dg::create::dy( g, p.bc["density"][1]) ),
    m_dy_U( dg::create::dy( g, p.bc["velocity"][1]) ),
    m_dy_P( dg::create::dy( g, p.bc["potential"][1]) ),
    m_dz( dg::create::dz( g, dg::PER) ),
    /////////the elliptic and Helmholtz operators//////////////////////////
    m_lapperpN ( g, p.bc["density"][0], p.bc["density"][1],  dg::normed,
        dg::centered),
    m_lapperpU ( g, p.bc["velocity"][0],p.bc["velocity"][1], dg::normed,
        dg::centered),
    m_multigrid( g, m_p.stages),
    m_old_phi( 2, dg::evaluate( dg::zero, g)),
    m_old_psi( 2, dg::evaluate( dg::zero, g)),
    m_old_gammaN( 2, dg::evaluate( dg::zero, g)),
    m_p(p), m_gp(gp), m_evec(5)
{
    ////////////////////////////init temporaries///////////////////
    dg::assign( dg::evaluate( dg::zero, g), m_chi );
    m_omega = m_lambda = m_chi;
    m_phi[0] = m_phi[1] = m_chi;
    m_dxPhi = m_dyPhi = m_dzPhi = m_npe = m_logn = m_dxN = m_dyN = m_dzN = m_phi;
    m_dxU = m_dyU = m_dzU = m_phi;
    //////////////////////////////init fields /////////////////////
    dg::assign(  dg::pullback(dg::geo::InvB(mag),      g), m_binv);
    dg::assign(  dg::pullback(dg::geo::GradLnB(mag),   g), m_gradlnB);
    dg::assign(  dg::pullback(dg::geo::TanhSource(mag.psip(), gp.psipmin, gp.alpha),         g), m_source);
    ////////////////////////////transform curvature components////////
    dg::geo::TokamakMagneticField mag = dg::geo::createSolovevField(gp);
    if( p.curvmode == "toroidal")
        mag = dg::geo::createToroidalField(gp);
    const dg::geo::BinaryVectorLvl0 bhat, curvNabla, curvKappa;
    if( p.curvmode == "true" || p.curvmode == "toroidal")
    {
        bhat = dg::geo::createBHat(mag);
        curvNabla = dg::geo::createTrueCurvatureNablaB(mag);
        curvKappa = dg::geo::createTrueCurvatureKappa(mag);
        dg::assign(  dg::pullback(dg::geo::TrueDivCurvatureKappa(mag), g),
            m_divCurvKappa);
    }
    else if( p.curvmode == "low beta")
    {
        bhat = dg:geo::createEPhi();
        curvNabla = curvKappa = dg::geo::createCurvatureNablaB(mag);
        dg::assign(  dg::pullback(dg::zero, g), m_divCurvKappa);
    }
    else if( p.curvmode == "toroidal approx")
    {
        bhat = dg:geo::createEPhi();
        curvNabla = dg::geo::createCurvatureNablaB(mag);
        curvKappa = dg::geo::createCurvatureKappa(mag);
        dg::assign(  dg::pullback(dg::geo::DivCurvatureKappa(mag), g),
            m_divCurvKappa);
    }
    dg::pushForwardPerp(bhat.x(), bhat.y(), bhat.z(), m_b[0], m_b[1], m_b[2], g);
    m_metric = g.metric();
    dg::tensor::inv_multiply3d( m_metric, m_b[0], m_b[1], m_b[2],
                                          m_b[0], m_b[1], m_b[2]);
    container vol = dg::tensor::volume(m_metric);
    dg::blas1::pointwiseDivide( m_binv, vol, vol); //1/vol/B
    for( int i=0; i<3; i++)
        dg::blas1::pointwiseDot( vol, m_b[i], m_b[i]); //b_i/vol/B
    dg::pushForwardPerp(curvNabla.x(), curvNabla.y(), curvNabla.z(),
        m_curv[0], m_curv[1], m_curv[2], g);
    dg::pushForwardPerp(curvKappa.x(), curvKappa.y(), curvKappa.z(),
        m_curvKappa[0], m_curvKappa[1], m_curvKappa[2], g);
    dg::blas1::axpby( 1., m_curvKappa, 1., m_curv);
    m_ds_U.construct( mag, g, g.bc["velocity"][0], g.bc["velocity"][1],
        dg::geo::NoLimiter(), dg::forward, gp.rk4eps, p.mx, p.my,
        2.*M_PI/(double)p.Nz ),
    m_ds_N.construct( mag, g, g.bc["density"][0], g.bc["density"][1],
        dg::geo::NoLimiter(), dg::forward, gp.rk4eps, p.mx, p.my,
        2.*M_PI/(double)p.Nz),
    m_ds_P.construct( mag, g, g.bc["potential"][0], g.bc["potential"][1],
        dg::geo::NoLimiter(), dg::forward, gp.rk4eps, p.mx, p.my,
        2.*M_PI/(double)p.Nz),
    //////////////////////////////init elliptic and helmholtz operators/////////
    m_multi_chi = m_multigrid.project( m_chi);
    m_multi_pol.resize(m_p.stages);
    m_multi_invgammaDIR.resize(m_p.stages);
    m_multi_invgammaN.resize(m_p.stages);
    for( unsigned u=0; u<m_p.stages; u++)
    {
        dg::SparseTensor<dg::DVec> hh = dg::geo::createProjectionTensor(
            bhat, m_multigrid.grids()[u].get());
        m_multi_pol[u].construct(        m_multigrid.grids()[u].get(),
            p.bc["potential"][0], p.bc["potential"][1], dg::not_normed,
            dg::centered, m_p.jfactor);
        m_multi_pol[u].set_chi( hh);
        m_multi_invgammaP[u].construct(  m_multigrid.grids()[u].get(),
            p.bc["potential"][0], p.bc["potential"][1],
            -0.5*m_p.tau[1]*m_p.mu[1], dg::centered);
        m_multi_invgammaP[u].elliptic().set_chi( hh);
        m_multi_invgammaN[u].construct(  m_multigrid.grids()[u].get(),
            p.bc["density"][0], p.bc["density"][1],
            -0.5*m_p.tau[1]*m_p.mu[1], dg::centered);
        m_multi_invgammaN[u].elliptic().set_chi( hh);
    }
    dg::SparseTensor<dg::DVec> hh = dg::geo::createProjectionTensor( bhat, grid);
    m_lapperpN.set_chi( hh);
    m_lapperpU.set_chi( hh);
    ///////////////////init densities//////////////////////////////
    dg::assign( dg::pullback(dg::geo::Nprofile(
        p.bgprofamp, p.nprofileamp, gp, mag.psip()),g), m_profne);
    //////////////////////////////Metric///////////////////////////////
    dg::assign( dg::create::volume(g), m_vol3d);
}

template<class Geometry, class IMatrix, class Matrix, class container>
void Explicit<Geometry, IMatrix, Matrix, container>::initializene( const container& src, container& target)
{
    if (m_p.tau[1] == 0.) {
        dg::blas1::copy( src, target); //  ne-1 = N_i -1
    }
    else {  //ne-1 = Gamma (ni-1)
        std::vector<unsigned> number = m_multigrid.direct_solve(
            m_multi_invgammaN, target, src, m_p.eps_gamma);
        if(  number[0] == m_multigrid.max_iter())
        throw dg::Fail( m_p.eps_gamma);
    }
}

template<class Geometry, class IMatrix, class Matrix, class container>
void Explicit<Geometry, IMatrix, Matrix, container>::compute_phi( double time, const std::array<container,2>& y)
{
    //y[0]:= n_e - 1
    //y[1]:= N_i - 1

    //First, compute and set chi
    dg::blas1::subroutine( ComputeChi(), m_chi, y[1], m_binv, m_p.mu[1]);
    m_multigrid.project( m_chi, m_multi_chi);
    for( unsigned u=0; u<m_p.stages; u++)
        m_multi_pol[u].set_chi( m_multi_chi[u]);

    //Now, compute right hand side
    if (m_p.tau[1] == 0.) {
        //compute N_i - n_e
        dg::blas1::axpby( 1., y[1], -1., y[0], m_chi);
    }
    else
    {
        //compute Gamma N_i - n_e
        m_old_gammaN.extrapolate( time, m_chi);
        std::vector<unsigned> numberG = m_multigrid.direct_solve(
            m_multi_invgammaN, m_chi, y[1], m_p.eps_gamma);
        m_old_gammaN.update( time, m_chi);
        if(  numberG[0] == m_multigrid.max_iter())
            throw dg::Fail( m_p.eps_gamma);
        dg::blas1::axpby( -1., y[0], 1., m_chi, m_chi);
    }
    //----------Invert polarisation----------------------------//
    m_old_phi.extrapolate( time, m_phi[0]);
    std::vector<unsigned> number = m_multigrid.direct_solve(
        m_multi_pol, m_phi[0], m_chi, m_p.eps_pol);
    m_old_phi.update( time, m_phi[0]);
    if(  number[0] == m_multigrid.max_iter())
        throw dg::Fail( m_p.eps_pol);
    //---------------------------------------------------------//
    //Solve for Gamma Phi
    if (m_p.tau[1] == 0.) {
        dg::blas1::copy( m_phi[0], m_phi[1]);
    } else {
        m_old_psi.extrapolate( time, m_phi[1]);
        std::vector<unsigned> number = m_multigrid.direct_solve(
            m_multi_invgammaP, m_phi[1], m_phi[0], m_p.eps_gamma);
        m_old_psi.update( time, m_phi[1]);
        if(  number[0] == m_multigrid.max_iter())
            throw dg::Fail( m_p.eps_gamma);
    }
    //-------Compute Psi and derivatives
    dg::blas2::symv( m_dx_P, m_phi[0], m_dxPhi[0]);
    dg::blas2::symv( m_dy_P, m_phi[0], m_dyPhi[0]);
    dg::blas2::symv( m_dz  , m_phi[0], m_dzPhi[0]);
    dg::tensor::multiply3d( m_metric,
        m_dxPhi[0], m_dyPhi[0], m_dzPhi[0], m_omega, m_chi, m_lambda);
    dg::blas1::subroutine( ComputePsi(),
        m_phi[1], m_dxPhi[0], m_dyPhi[0], m_dzPhi[0],
        m_omega, m_chi, m_lambda, m_binv);
    //m_omega now contains u_E^2; also update derivatives
    dg::blas2::symv( m_dx_P, m_phi[1], m_dxPhi[1]);
    dg::blas2::symv( m_dy_P, m_phi[1], m_dyPhi[1]);
    dg::blas2::symv( m_dz  , m_phi[1], m_dzPhi[1]);
}

template<class Geometry, class IMatrix, class Matrix, class container>
void Explicit<Geometry, IMatrix, Matrix, container>::operator()( double t, const std::array<std::array<container,2>,2>& y, std::array<std::array<container,2>,2>& yp)
{
    /* y[0][0] := N_e - 1
       y[0][1] := N_i - 1
       y[1][0] := U_e
       y[1][1] := U_i
    */
    dg::Timer timer;
    timer.tic();

    //Set phi[0], phi[1], m_dxPhi, m_dyPhi, and m_omega (u_E^2)
    compute_phi( y[0]);
    //Transform n-1 to n and n to logn
    dg::blas1::subroutine( ComputeLogN(), y[0], m_npe, m_logn);
    ////////////////////ENERGETICS///////////////////////////////////////
    double z[2]    = {-1.0,1.0};

    m_q.mass = dg::blas1::dot( m_vol3d, y[0][0]);
    //compute energies
    for(unsigned i=0; i<2; i++)
    {
        m_q.S[i]    = z[i]*m_p.tau[i]*dg::blas2::dot( m_logn[i], m_vol3d, m_npe[i]);
        dg::blas1::pointwiseDot( y[1][i], y[1][i], m_chi); //U^2
        m_q.Tpar[i] = z[i]*0.5*m_p.mu[i]*dg::blas2::dot( m_npe[i], m_vol3d, m_chi);
    }
    m_q.Tperp = 0.5*m_p.mu[1]*dg::blas2::dot( m_npe[1], m_vol3d, m_omega);   //= 0.5 mu_i N_i u_E^2
    m_q.energy = m_q.S[0] + m_q.S[1]  + m_q.Tperp + m_q.Tpar[0] + m_q.Tpar[1];
    ///////////////////////////////////EQUATIONS///////////////////////////////
    for( unsigned i=0; i<2; i++)
    {
        ////////////////////perpendicular dynamics////////////////////////
        dg::blas2::gemv( m_dx_N, y[0][i], m_dxN[i]);
        dg::blas2::gemv( m_dy_N, y[0][i], m_dyN[i]);
        dg::blas2::gemv( m_dx_U, y[1][i], m_dxU[i]);
        dg::blas2::gemv( m_dy_U, y[1][i], m_dyU[i]);
        dg::blas2::gemv( m_dz,  y[0][i], m_dzN[i]);
        dg::blas2::gemv( m_dz,  y[1][i], m_dzU[i]);
        dg::blas1::subroutine( ComputePerpDrifts(m_p.mu[i], m_p.tau[i]),
            //species depdendent
            y[0][i], m_dxN[i], m_dyN[i], m_dzN[i],
            y[1][i], m_dxU[i], m_dyU[i], m_dzU[i],
            m_dxPhi[i], m_dyPhi[i], m_dzPhi[i],
            //magnetic parameters
            m_binv, m_b[0], m_b[1], m_b[2],
            m_curv[0], m_curv[1], m_curv[2],
            m_curvKappa[0], m_curvKappa[1], m_curvKappa[2],
            m_divCurvKappa, yp[0][i], yp[1][i]
        );

        ///////////parallel dynamics///////////////////////////////
        //velocity
        //Burgers term
        dg::blas1::pointwiseDot(y[1][i], y[1][i], m_omega); //U^2
        m_ds_U.centered(-0.5, m_omega, 1., yp[1][i]); //dtU += -0.5 ds U^2
        //parallel force terms
        m_ds_N.centered(-m_p.tau[i]/m_p.mu[i], m_logn[i], 1.0, yp[1][i]);
        m_ds_P.centered(-1./m_p.mu[i], m_phi[i], 1.0, yp[1][i]);        //dtU += - tau/(hat(mu))*ds lnN - 1/(hat(mu))*ds psi

        //density
        m_ds_P.centered( m_phi[i], m_dsPhi[i]);
        m_ds_N.centered( y[0][i], m_dsN[i]);
        m_ds_U.centered( y[1][i], m_dsU[i]);
        dg::blas1::pointwiseDot(-1., m_dsN[i], y[1][i], 1.,
            -1., y[0][i], m_dsU[i], yp[0][i] );   // dsN*U + N* dsU
        dg::blas1::pointwiseDot( 1., y[0][i],y[1][i],m_gradlnB, 1., yp[0][i]);// dtN += U N ds ln B

        //direct parallel diffusion for N and U
        m_ds_N.dss( y[0][i], m_dsN[i]);
        m_ds_U.dss( y[1][i], m_dsU[i]);
        dg::blas1::axpby( m_p.nu_parallel, m_dsN[i], 1., yp[0][i]);
        dg::blas1::axpby( m_p.nu_parallel, m_dsU[i], 1., yp[1][i]);
        dg::blas1::pointwiseDot( -m_p.nu_parallel, gradlnB, m_dsN[i],                  -m_p.nu_parallel, gradlnB, m_dsU[i], 1., yp[1][i]);

    }
    //Add Resistivity
    dg::blas1::subroutine( AddResistivity( m_p.c, m_p.mu),
        y[0][0], y[0][1], y[1][0], y[1][1], yp[1][0], yp[1][1]);
    //Add particle source to dtN
    dg::blas1::subroutine( ComputeSource(),
        m_lambda, y[0][0], m_profne, m_source, m_p.omega_source);
    dg::blas1::axpby( 1., m_lambda, 1.0, yp[0][0]);
    dg::blas1::axpby( 1., m_lambda, 1.0, yp[1][1]);
    //add FLR correction to dtNi
    dg::blas2::gemv( -0.5*m_p.tau[1]*m_p.mu[1], m_lapperpN, m_lambda, 1.0, yp[1][1]);
    /////////////////ENERGY DISSIPATION TERMS//////////////////////////////
    // energy dissipation through diffusion
    for( unsigned i=0; i<2;i++)
    {

        dg::blas1::subroutine( ComputeDiss(m_p.mu[i], m_p.tau[i]),
            m_chi, m_logn[i], m_phi[i], y[1][i]); //chi = tau(1+lnN) + phi + 0.5 mu U^2
        //Compute parallel dissipation for N
        m_q.Dpar[i] = z[i]*p.nu_parallel*dg::blas2::dot(m_chi, m_vol3d, m_dsN[i]);
                //Z*(tau (1+lnN )+psi + 0.5 mu U^2) nu_parallel *(Delta_s N)
        if( i==0) //only electrons
        {
            dg::blas1::transform( m_logn[i],m_omega, dg::PLUS<>(+1)); //omega = (1+lnN)
            m_q.aligned = dg::blas2::dot( m_omega, m_vol3d, m_dsN[i]); //(1+lnN)*Delta_s N
        }
        //Compute perp dissipation for N
        dg::blas2::gemv( m_lapperpN, y[0][i], m_lambda);
        dg::blas2::gemv( m_lapperpN, m_lambda, m_omega);//Delta^2 N
        m_q.Dperp[i] = -z[i]* m_p.nu_perp*dg::blas2::dot(m_chi, m_vol3d, m_omega);

        dg::blas1::pointwiseDot( m_npe[i], y[1][i], m_omega); // omega = N U
        //Compute parallel dissipation for U
        m_q.Dpar[i+2] = z[i]*m_p.mu[i]*m_p.nu_parallel*dg::blas2::dot(m_omega, m_vol3d, m_dsU[i]);      //Z*mu*N*U nu_parallel *( Delta_s U)
        //Compute perp dissipation  for U
        dg::blas2::gemv( m_lapperpU, y[1][i], m_lambda);
        dg::blas2::gemv( m_lapperpU, m_lambda,m_chi);//Delta^2 U
        m_q.Dperp[i+2] = -z[i]*m_p.mu[i]*m_p.nu_perp
            *dg::blas2::dot(m_omega, m_vol3d, m_chi);
    }
    // resistive energy (quadratic current)
    dg::blas1::pointwiseDot(1., m_npe[0], y[1][1], -1., m_npe[0], y[1][0],
        0., m_omega); // omega = n_e (U_i - u_e)
    m_q.Dres = -m_p.c*dg::blas2::dot(m_omega, m_vol3d, m_omega); //- C*(N_e (U_i - U_e))^2
    m_q.ediff = m_q.Dres + m_q.Dpar[0]+m_q.Dperp[0]+m_q.Dpar[1]+m_q.Dperp[1]
        +m_q.Dpar[2]+m_q.Dperp[2]+m_q.Dpar[3]+m_q.Dperp[3];

    timer.toc();
    #ifdef MPI_VERSION
        int rank;
        MPI_Comm_rank( MPI_COMM_WORLD, &rank);
        if(rank==0)
    #endif
    std::cout << "One rhs took "<<timer.diff()<<"s\n";
}

} //namespace feltor
