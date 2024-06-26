//
//    Copyright 2013, Tarje Nissen-Meyer, Alexandre Fournier, Martin van Driel
//                    Simon Stahler, Kasra Hosseini, Stefanie Hempel
//
//    This file is part of AxiSEM.
//    It is distributed from the webpage <http://www.axisem.info>
//
//    AxiSEM is free software: you can redistribute it and/or modify
//    it under the terms of the GNU General Public License as published by
//    the Free Software Foundation, either version 3 of the License, or
//    (at your option) any later version.
//
//    AxiSEM is distributed in the hope that it will be useful,
//    but WITHOUT ANY WARRANTY; without even the implied warranty of
//    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//    GNU General Public License for more details.
//
//    You should have received a copy of the GNU General Public License
//    along with AxiSEM.  If not, see <http://www.gnu.org/licenses/>.
//

#ifndef _CRAYC
//#include <xmmintrin.h>
#ifdef __GNUC__ // only use these features on gnu compiler
#ifdef HAVE_XMMINTRIN
  #define FORCE_FTZ
  #include <xmmintrin.h>
#elif HAVE_EMMINTRIN
  #include <emmintrin.h>
  #define FORCE_FTZ
#endif
#endif // __GNUC__
#endif

// A Fortran callable function to activate flush to zero for denormal float handling
// http://software.intel.com/en-us/articles/how-to-avoid-performance-penalties-for-gradual-underflow-behavior
// http://stackoverflow.com/questions/9314534/why-does-changing-0-1f-to-0-slow-down-performance-by-10x

#if defined(__GNUC__) || defined(linux)
  #define set_ftz set_ftz_
#endif

void set_ftz(){
#ifndef _CRAYC
#ifdef FORCE_FTZ
  _MM_SET_FLUSH_ZERO_MODE (_MM_FLUSH_ZERO_ON);
#endif
#endif
}

