ifeq ($(OS),ubuntu1404)
#default machine values
INCLUDE = -I$(HOME)/include#  # cusp and thrust and the draw libraries
INCLUDE += -I/usr/include/hdf5/serial
GLFLAGS =$$(pkg-config --static --libs glfw3) #glfw3 installation
CC=g++ #C++ compiler
MPICC=mpic++  #mpi compiler
OPT=-O3 # optimization flag
NVCCARCH=-arch sm_20 #nvcc gpu compute capability
OMPFLAG=-fopenmp #openmp flag for CC and MPICC
LIBS=-lnetcdf -lhdf5 -lhdf5_hl # netcdf library for file output
JSONLIB=-I/usr/include/jsoncpp -ljsoncpp
endif # ubuntu1504
