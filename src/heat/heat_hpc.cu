#include <iostream>
#include <iomanip>
#include <vector>
#include <sstream>
#include <cmath>
// #define DG_DEBUG

#include <cusp/coo_matrix.h>
#include <cusp/print.h>
#include "json/json.h"

#include "dg/file/nc_utilities.h"
#include "dg/algorithm.h"
#include "dg/geometries/geometries.h"

#include "parameters.h"
#include "heat.cuh"

int main( int argc, char* argv[])
{
    ////Parameter initialisation ///////////////////////////////////////
    Json::Value js, gs;
    Json::CharReaderBuilder parser;
    //read input without comments
    parser["collectComments"] = false;
    std::string errs;
    if(!(( argc == 4) || ( argc == 5)) )
    {
        std::cerr << "ERROR: Wrong number of arguments!\nUsage: "<< argv[0]<<" [inputfile] [geomfile] [output.nc] [input.nc]\n";
        std::cerr << "OR "<< argv[0]<<" [inputfile] [geomfile] [output.nc] \n";
        return -1;
    }
    else
    {
        std::ifstream is(argv[1]);
        std::ifstream ks(argv[2]);
        parseFromStream( parser, is, &js, &errs);
        parseFromStream( parser, ks, &gs, &errs);
    }
    const heat::Parameters p( js); p.display( std::cout);
    const dg::geo::solovev::Parameters gp(gs); gp.display( std::cout);
    ////////////////////////////set up computations//////////////////////

    double Rmin=gp.R_0-p.boxscaleRm*gp.a;
    double Zmin=-p.boxscaleZm*gp.a*gp.elongation;
    double Rmax=gp.R_0+p.boxscaleRp*gp.a;
    double Zmax=p.boxscaleZp*gp.a*gp.elongation;

    //Make grids
    dg::CylindricalGrid3d grid( Rmin,Rmax, Zmin,Zmax, 0, 2.*M_PI,
        p.n, p.Nx, p.Ny, p.Nz, p.bcx, p.bcy, dg::PER);
    dg::CylindricalGrid3d grid_out( Rmin,Rmax, Zmin,Zmax, 0, 2.*M_PI,
        p.n_out, p.Nx_out, p.Ny_out,p.Nz_out,p.bcx, p.bcy, dg::PER);
    dg::DVec w3d =  dg::create::volume(grid);
    dg::DVec w3dout =  dg::create::volume(grid_out);

    // /////////////////////get last temperature field of sim
    dg::DVec Tend(dg::evaluate(dg::zero,grid_out));
    dg::DVec Tendc(dg::evaluate(dg::zero,grid));
    dg::DVec transfer(  dg::evaluate(dg::zero, grid));

    dg::DVec transferD( dg::evaluate(dg::zero, grid_out));
    dg::HVec transferH( dg::evaluate(dg::zero, grid_out));
    dg::HVec transferHc( dg::evaluate(dg::zero, grid));
    int  tvarID;
    //////////////////////////////open nc file//////////////////////////////////
    if (argc == 5)
    {
        file::NC_Error_Handle errin;
        int ncidin;
        errin = nc_open( argv[4], NC_NOWRITE, &ncidin);
        //////////////read in and show inputfile und geomfile////////////
        size_t length;
        errin = nc_inq_attlen( ncidin, NC_GLOBAL, "inputfile", &length);
        std::string inputin( length, 'x');
        errin = nc_get_att_text( ncidin, NC_GLOBAL, "inputfile", &inputin[0]);
        errin = nc_inq_attlen( ncidin, NC_GLOBAL, "geomfile", &length);
        std::string geomin( length, 'x');
        errin = nc_get_att_text( ncidin, NC_GLOBAL, "geomfile", &geomin[0]);
        std::cout << "input in"<<inputin<<std::endl;
        std::cout << "geome in"<<geomin <<std::endl;
        std::stringstream is;
        is.str( inputin);
        parseFromStream( parser, is, &js, &errs);
        is.str( geomin);
        parseFromStream( parser, is, &gs, &errs);
        const heat::Parameters pin(js);
        const dg::geo::solovev::Parameters gpin(gs);
        size_t start3din[4]  = {pin.maxout, 0, 0, 0};
        size_t count3din[4]  = {1, pin.Nz, pin.n*pin.Ny, pin.n*pin.Nx};
        std::string namesin = {"T"};
        int dataIDin;
        errin = nc_inq_varid(ncidin, namesin.data(), &dataIDin);
        errin = nc_get_vara_double( ncidin, dataIDin, start3din,
                                    count3din, transferH.data());
        dg::assign(transferH, Tend);
        errin = nc_close(ncidin);
    }
    // /////////////////////create RHS
    std::cout << "Constructing Feltor...\n";
    heat::Explicit<dg::CylindricalGrid3d, dg::IDMatrix, dg::DMatrix, dg::DVec> ex( grid, p,gp); //initialize before diffusion!
    std::cout << "initialize implicit" << std::endl;
    heat::Implicit<dg::CylindricalGrid3d, dg::IDMatrix, dg::DMatrix, dg::DVec > diffusion( grid, p,gp);
    std::cout << "Done!\n";

    //////////////////The initial field/////////////////////////////////
    //initial perturbation
    dg::Gaussian3d init0(gp.R_0+p.posX*gp.a, p.posY*gp.a, M_PI, p.sigma, p.sigma, p.sigma_z, p.amp);

    //background profile
    dg::geo::Nprofile prof(0, p.nprofileamp, gp, dg::geo::solovev::Psip(gp)); //initial background profile
    dg::DVec y0(dg::evaluate( prof, grid)), y1(y0);
    //field aligning
    dg::GaussianZ gaussianZ( 0., p.sigma_z*M_PI, 1);
    y1 = ex.ds().fieldaligned().evaluate( init0, gaussianZ, (unsigned)p.Nz/2, 3); //rounds =2 ->2*2-1
    dg::blas1::axpby( 1., y1, 1., y0); //initialize y0
    ///////////////////TIME STEPPER
    dg::Adaptive<dg::ARKStep<dg::DVec>> adaptive(
        y0, "ARK-4-2-3", grid.size(), p.eps_time);
    double dt = p.dt, dt_new = dt;
    // dg::Karniadakis< dg::DVec > karniadakis( y0, y0.size(),1e-13);
     //karniadakis.init( ex, diffusion, 0, y0, p.dt);

    ex.energies( y0);//now energies and potential are at time 0
    dg::DVec T0 = y0, T1(T0);
    double normT0 = dg::blas2::dot( T0, w3d, T0);
    /////////////////////////////set up netcdf for output/////////////////////////////////////

    file::NC_Error_Handle err;
    int ncid;
    err = nc_create( argv[3],NC_NETCDF4|NC_CLOBBER, &ncid);
    std::string input = js.toStyledString();
    err = nc_put_att_text( ncid, NC_GLOBAL, "inputfile", input.size(), input.data());
    std::string geom = gs.toStyledString();
    err = nc_put_att_text( ncid, NC_GLOBAL, "geomfile", geom.size(), geom.data());
    int dim_ids[4];
    err = file::define_dimensions( ncid, dim_ids, &tvarID, grid_out);

    //energy IDs
    int EtimeID, EtimevarID;
    err = file::define_time( ncid, "energy_time", &EtimeID, &EtimevarID);
    std::string names0d []= { "heat", "entropy", "dissipation",
        "entropy_dissipation", "accuracy", "error", "relerror"};
    std::map<std::string, int> id0d;
    std::map<std::string, double> value0d;
    for( auto name : names0d)
        err = nc_def_var( ncid, name.data(), NC_DOUBLE, 1, &EtimeID, &id0d[name]);
    std::string names3d [] = {"T"};
    std::map<std::string, int> id3d;
    std::map<std::string, dg::HVec> value3d;
    for( auto name : names3d)
        err = nc_def_var( ncid, name.data(), NC_DOUBLE, 4, dim_ids, &id3d[name]);

    err = nc_enddef(ncid);
    ///////////////////////////////////first output/////////////////////////
    std::cout << "First output ... \n";
    size_t start[4] = {0, 0, 0, 0};
    size_t count[4] = {1, grid_out.Nz(), grid_out.n()*grid_out.Ny(), grid_out.n()*grid_out.Nx()};

    //interpolate fine 2 coarse grid
    dg::IDMatrix interpolatef2c = dg::create::interpolation( grid, grid_out);//f2c

    transferD =y0; // dont interpolate field
    err = nc_open(argv[3], NC_WRITE, &ncid);
    dg::assign(transferD, value3d["T"]);
    err = nc_put_vara_double( ncid, id3d["T"], start, count, value3d["T"].data());

    double time = 0;
    err = nc_put_vara_double( ncid, tvarID, start, count, &time);
    err = nc_put_vara_double( ncid, EtimevarID, start, count, &time);

    size_t Estart[] = {0};
    size_t Ecount[] = {1};
    double entropy0 = ex.entropy(), heat0 = ex.energy(); //at time 0
    double E0 = entropy0;
    dg::blas1::axpby( 1., y0, -1.,T0, T1);

    //Compute error to reference solution
    value0d["error"] = sqrt(dg::blas2::dot( w3d, T1)/normT0);
    value0d["relerror"]=0.;
    if (argc==5)
    {
        // interpolate fine grid one coarse grid
        dg::blas2::symv( interpolatef2c, Tend, Tendc);
        dg::blas1::axpby( 1., y0, -1.,Tendc,transfer);
        value0d["relerror"] = sqrt(dg::blas2::dot( w3d, transfer)/dg::blas2::dot(w3dout,Tend));
    }
    value0d["heat"] = ex.energy();
    value0d["entropy"] = ex.entropy();
    value0d["dissipation"] = ex.energy_diffusion();
    value0d["entropy_dissipation"] = ex.entropy_diffusion();
    value0d["accuracy"] = 0.;
    for( auto name : names0d)
        err = nc_put_vara_double( ncid, id0d[name], Estart, Ecount, &value0d[name]);
    err = nc_close(ncid);
    std::cout << "First write successful!\n";

    ///////////////////////////////////////Timeloop/////////////////////////////////
    dg::Timer t;
    t.tic();
    unsigned step = 0;
    for( unsigned i=1; i<=p.maxout; i++)
    {

#ifdef DG_BENCHMARK
        dg::Timer ti;
        ti.tic();
#endif//DG_BENCHMARK
        for( unsigned j=0; j<p.itstp; j++)
        {
            try{
//                 rk.step( ex, time,y0, time,y0, p.dt); //RK stepper
                dt = dt_new;
                adaptive.step(ex,diffusion,time,y0,time,y0,dt_new, dg::pid_control, dg::l2norm, 1e-5, 1e-10);
                 //karniadakis.step( ex, diffusion, time, y0);  //Karniadakis stepper
              }
              catch( dg::Fail& fail) {
                std::cerr << "CG failed to converge to "<<fail.epsilon()<<"\n";
                std::cerr << "Does Simulation respect CFL condition?\n";
                err = nc_close(ncid);
                return -1;}
            step++;
            ex.energies(y0);//advance potential and energies
            Estart[0] = step;
            value0d["entropy"] = ex.entropy();
            value0d["heat"] = ex.energy();
            value0d["entropy_dissipation"] = ex.entropy_diffusion();
            value0d["heat_dissipation"] = ex.energy_diffusion();
            double dEdt = (value0d["entropy"] - E0)/dt;
            value0d["accuracy"] = 2.*fabs(
                            (dEdt - value0d["entropy_dissipation"])/
                            (dEdt + value0d["entropy_dissipation"]));
            E0 = value0d["entropy"];
            //compute errors
            dg::blas1::axpby( 1., y0, -1.,T0, T1);
            value0d["error"] = sqrt(dg::blas2::dot( w3d, T1)/normT0);
            if (argc==5)
            {
                //interpolate fine on coarse grid
                dg::blas2::symv( interpolatef2c, Tend, Tendc);
                dg::blas1::axpby( 1., y0, -1.,Tendc,transfer);
                value0d["relerror"] = sqrt(dg::blas2::dot(w3d, transfer)/dg::blas2::dot(w3dout,Tend));

            }
            err = nc_open(argv[3], NC_WRITE, &ncid);
            err = nc_put_vara_double( ncid, EtimevarID, Estart, Ecount, &time);
            for( auto name : names0d)
                err = nc_put_vara_double( ncid, id0d[name], Estart, Ecount, &value0d[name]);

            std::cout <<"(Q_tot-Q_0)/Q_0: "
                      << (ex.energy()-heat0)/heat0<<"\t";
            std::cout <<"(E_tot-E_0)/E_0: "
                      << (ex.entropy()-entropy0)/entropy0<<"\t";
            std::cout <<" d E/dt = " << dEdt
                      <<" Lambda = " << ex.entropy_diffusion()
                      <<" -> Accuracy: "<< value0d["accuracy"]
                      <<" -> error2t0: "<< value0d["error"]
                      <<" -> error2ref: "<< value0d["relerror"] <<"\n";
            err = nc_close(ncid);
        }
#ifdef DG_BENCHMARK
        ti.toc();
        std::cout << "\n\t Step "<<step <<" of "<<p.itstp*p.maxout <<" at time "<<time;
        std::cout << "\n\t Average time for one step: "<<ti.diff()/(double)p.itstp<<"s\n\n"<<std::flush;
#endif//DG_BENCHMARK
        //////////////////////////write fields////////////////////////
        start[0] = i;

        transferD = y0; //dont interpolate field
        dg::assign(transferD, value3d["T"]);
        err = nc_open(argv[3], NC_WRITE, &ncid);
        err = nc_put_vara_double( ncid, id3d["T"], start, count, value3d["T"].data());
        err = nc_put_vara_double( ncid, tvarID, start, count, &time);
        err = nc_close(ncid);
    }
    t.toc();
    unsigned hour = (unsigned)floor(t.diff()/3600);
    unsigned minute = (unsigned)floor( (t.diff() - hour*3600)/60);
    double second = t.diff() - hour*3600 - minute*60;
    std::cout << std::fixed << std::setprecision(2) <<std::setfill('0');
    std::cout <<"Computation Time \t"<<hour<<":"<<std::setw(2)<<minute<<":"<<second<<"\n";
    std::cout <<"which is         \t"<<t.diff()/p.itstp/p.maxout<<"s/step\n";

    return 0;

}

