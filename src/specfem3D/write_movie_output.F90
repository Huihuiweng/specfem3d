!=====================================================================
!
!                          S p e c f e m 3 D
!                          -----------------
!
!     Main historical authors: Dimitri Komatitsch and Jeroen Tromp
!                              CNRS, France
!                       and Princeton University, USA
!                 (there are currently many more authors!)
!                           (c) October 2017
!
! This program is free software; you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation; either version 3 of the License, or
! (at your option) any later version.
!
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License along
! with this program; if not, write to the Free Software Foundation, Inc.,
! 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
!
!=====================================================================


#include "config.fh"

  subroutine write_movie_output()

  use specfem_par
  use specfem_par_movie
  use specfem_par_elastic
  use specfem_par_acoustic

  ! hdf5 i/o server
  use io_server_hdf5, only: wait_all_send

  implicit none

  if (.not. MOVIE_SIMULATION) return

  ! gets resulting array values onto CPU
  if (GPU_MODE .and. &
    ( &
      CREATE_SHAKEMAP .or. &
      ( MOVIE_SURFACE .and. mod(it,NTSTEP_BETWEEN_FRAMES) == 0) .or. &
      ( MOVIE_VOLUME .and. mod(it,NTSTEP_BETWEEN_FRAMES) == 0) .or. &
      ( PNM_IMAGE .and. mod(it,NTSTEP_BETWEEN_FRAMES) == 0) &
     )) then
    ! acoustic domains
    if (ACOUSTIC_SIMULATION) then
      ! transfers whole fields
      call transfer_fields_ac_from_device(NGLOB_AB, &
                                          potential_acoustic,potential_dot_acoustic,potential_dot_dot_acoustic,Mesh_pointer)
    endif
    ! elastic domains
    if (ELASTIC_SIMULATION) then
      ! transfers whole fields
      call transfer_fields_el_from_device(NDIM*NGLOB_AB, &
                                          displ,veloc,accel,Mesh_pointer)
    endif
  endif

  ! computes SHAKING INTENSITY MAP
  if (CREATE_SHAKEMAP) then
    call wmo_create_shakemap()
  endif

  ! file output
  if (mod(it,NTSTEP_BETWEEN_FRAMES) == 0) then
    ! hdf5 i/o server
    ! i/o server wait
    if (HDF5_IO_NODES > 0) call wait_all_send()

    ! saves MOVIE on the SURFACE
    if (MOVIE_SURFACE) then
      call wmo_movie_surface_output()
    endif

    ! saves MOVIE in full 3D MESH
    if (MOVIE_VOLUME) then
      call wmo_movie_volume_output()
    endif

    ! creates cross-section PNM image
    if (PNM_IMAGE) then
      call write_PNM_create_image()
    endif
  endif

  end subroutine write_movie_output



!================================================================

  subroutine wmo_movie_surface_output()

! output of moviedata files

! option MOVIE_TYPE == 1: only at top, free surface
!        MOVIE_TYPE == 2: for all external, outer mesh surfaces

  use specfem_par
  use specfem_par_elastic
  use specfem_par_acoustic
  use specfem_par_movie
  implicit none

  ! temporary array for single elements
  real(kind=CUSTOM_REAL),dimension(NDIM,NGLLX,NGLLY,NGLLZ) :: val_element
  integer :: ispec2D,ispec,ipoin,iglob,ia
  integer :: npoin_elem

  ! surface points for single face
  if (USE_HIGHRES_FOR_MOVIES) then
    npoin_elem = NGLLX*NGLLY
  else
    npoin_elem = NGNOD2D_FOUR_CORNERS
  endif

  ! saves surface velocities
  do ispec2D = 1,nfaces_surface
    ispec = faces_surface_ispec(ispec2D)

    if (ispec_is_acoustic(ispec)) then
      ! acoustic elements
      if (SAVE_DISPLACEMENT) then
        ! displacement vector
        call compute_gradient_in_acoustic(ispec,potential_acoustic,val_element)
      else
        ! velocity vector
        call compute_gradient_in_acoustic(ispec,potential_dot_acoustic,val_element)
      endif

      ! all surface element points
      do ipoin = 1, npoin_elem
        ia = npoin_elem * (ispec2D - 1) + ipoin
        iglob = faces_surface_ibool(ipoin,ispec2D)
        ! puts displ/velocity values into storage array
        call wmo_get_vel_vector(ispec,iglob,ia,val_element)
      enddo

    else if (ispec_is_elastic(ispec)) then
      ! elastic elements
      ! all surface element points
      do ipoin = 1, npoin_elem
        ia = npoin_elem * (ispec2D - 1) + ipoin
        iglob = faces_surface_ibool(ipoin,ispec2D)

        if (SAVE_DISPLACEMENT) then
          ! velocity x,y,z-components
          store_val_ux(ia) = displ(1,iglob)
          store_val_uy(ia) = displ(2,iglob)
          store_val_uz(ia) = displ(3,iglob)
        else
          ! velocity x,y,z-components
          store_val_ux(ia) = veloc(1,iglob)
          store_val_uy(ia) = veloc(2,iglob)
          store_val_uz(ia) = veloc(3,iglob)
        endif
      enddo
    endif
  enddo

  ! saves surface movie snapshot
  call wmo_movie_save_surface_snapshot()

  end subroutine wmo_movie_surface_output

!================================================================

  subroutine wmo_movie_save_surface_snapshot()

  use specfem_par
  use specfem_par_movie

  implicit none

  ! temporary array for single elements
  real(kind=CUSTOM_REAL),dimension(1):: dummy
  integer :: ier
  character(len=MAX_STRING_LEN) :: outputname

  ! selects routine for file i/o format
  if (HDF5_FOR_MOVIES) then
    call wmo_movie_save_surface_snapshot_hdf5()
    ! all done
    return
  else
    ! binary file
    ! implemented here below, continue
    continue
  endif

  ! updates/gathers velocity field
  if (myrank == 0) then
    call gatherv_all_cr(store_val_ux,nfaces_surface_points, &
                        store_val_ux_all,nfaces_perproc_surface,faces_surface_offset, &
                        nfaces_surface_glob_points,NPROC)
    call gatherv_all_cr(store_val_uy,nfaces_surface_points, &
                        store_val_uy_all,nfaces_perproc_surface,faces_surface_offset, &
                        nfaces_surface_glob_points,NPROC)
    call gatherv_all_cr(store_val_uz,nfaces_surface_points, &
                        store_val_uz_all,nfaces_perproc_surface,faces_surface_offset, &
                        nfaces_surface_glob_points,NPROC)
  else
    !secondarys
    call gatherv_all_cr(store_val_ux,nfaces_surface_points, &
                        dummy,nfaces_perproc_surface,faces_surface_offset, &
                        1,NPROC)
    call gatherv_all_cr(store_val_uy,nfaces_surface_points, &
                        dummy,nfaces_perproc_surface,faces_surface_offset, &
                        1,NPROC)
    call gatherv_all_cr(store_val_uz,nfaces_surface_points, &
                        dummy,nfaces_perproc_surface,faces_surface_offset, &
                        1,NPROC)
  endif

  ! file output
  if (myrank == 0) then
    write(outputname,"('/moviedata',i6.6)") it
    open(unit=IOUT,file=trim(OUTPUT_FILES)//outputname,status='unknown',form='unformatted',iostat=ier)
    if (ier /= 0) stop 'error opening file moviedata'
    write(IOUT) store_val_x_all   ! x coordinate
    write(IOUT) store_val_y_all   ! y coordinate
    write(IOUT) store_val_z_all   ! z coordinate
    write(IOUT) store_val_ux_all  ! velocity x-component
    write(IOUT) store_val_uy_all  ! velocity y-component
    write(IOUT) store_val_uz_all  ! velocity z-component
    close(IOUT)
  endif

  end subroutine wmo_movie_save_surface_snapshot

!================================================================

  subroutine wmo_get_vel_vector(ispec,iglob,ia,val_element)

  ! put into this separate routine to make compilation faster

  use constants, only: NDIM,NGLLX,NGLLY,NGLLZ,CUSTOM_REAL

  use specfem_par, only: ibool
  use specfem_par_movie, only: store_val_ux,store_val_uy,store_val_uz

  implicit none

  integer,intent(in) :: ispec,iglob,ia
  real(kind=CUSTOM_REAL),dimension(NDIM,NGLLX,NGLLY,NGLLZ),intent(in) :: val_element

  ! local parameters
  integer :: i,j,k

  do k=1,NGLLZ
    do j=1,NGLLY
      do i=1,NGLLX
        if (iglob == ibool(i,j,k,ispec)) then
          store_val_ux(ia) = val_element(1,i,j,k)
          store_val_uy(ia) = val_element(2,i,j,k)
          store_val_uz(ia) = val_element(3,i,j,k)

          ! point found, we are done
          return
        endif
      enddo
    enddo
  enddo

  end subroutine wmo_get_vel_vector

!================================================================

  subroutine wmo_create_shakemap()

! creation of shapemap file
!
! option MOVIE_TYPE == 1: uses horizontal peak-ground values, only at top, free surface
!        MOVIE_TYPE == 2: uses norm of vector as peak-ground, for all external, outer mesh surfaces
!        MOVIE_TYPE == 3: uses geometric mean of peak-ground values, only at top, free surface

  use specfem_par
  use specfem_par_elastic
  use specfem_par_acoustic
  use specfem_par_movie
  implicit none

  ! temporary array for single elements
  real(kind=CUSTOM_REAL),dimension(NDIM,NGLLX,NGLLY,NGLLZ) :: displ_element,veloc_element,accel_element
  real(kind=CUSTOM_REAL) :: gmean_PGD,gmean_PGV,gmean_PGA
  integer :: ipoin,ispec,iglob,ispec2D,ia
  integer :: npoin_elem

  ! note: shakemap arrays are initialized to zero after allocation

  ! surface points for single face
  if (USE_HIGHRES_FOR_MOVIES) then
    npoin_elem = NGLLX*NGLLY
  else
    npoin_elem = NGNOD2D_FOUR_CORNERS
  endif

  ! determines displacement, velocity and acceleration maximum amplitudes
  do ispec2D = 1,nfaces_surface
    ispec = faces_surface_ispec(ispec2D)

    if (ispec_is_acoustic(ispec)) then
      ! acoustic elements

      ! computes displ/veloc/accel for local element
      ! displacement vector
      call compute_gradient_in_acoustic(ispec,potential_acoustic,displ_element)
      ! velocity vector
      call compute_gradient_in_acoustic(ispec,potential_dot_acoustic,veloc_element)
      ! accel ?
      call compute_gradient_in_acoustic(ispec,potential_dot_dot_acoustic,accel_element)

      ! all surface element points
      do ipoin = 1, npoin_elem
        ia = npoin_elem * (ispec2D - 1) + ipoin
        iglob = faces_surface_ibool(ipoin,ispec2D)
        ! determines shakemap values for point
        call wmo_get_max_vector_shakemap(ispec,iglob,ia,displ_element,veloc_element,accel_element,MOVIE_TYPE)
      enddo

    else if (ispec_is_elastic(ispec)) then
      ! elastic elements
      ! all surface element points
      do ipoin = 1, npoin_elem
        ia = npoin_elem * (ispec2D - 1) + ipoin
        iglob = faces_surface_ibool(ipoin,ispec2D)

        select case (MOVIE_TYPE)
        case (1)
          ! PGD, PGV, PGA
          ! only top surface, using horizontal peak-ground value
          ! horizontal displacement
          shakemap_ux(ia) = max(shakemap_ux(ia),abs(displ(1,iglob)),abs(displ(2,iglob)))
          ! horizontal velocity
          shakemap_uy(ia) = max(shakemap_uy(ia),abs(veloc(1,iglob)),abs(veloc(2,iglob)))
          ! horizontal acceleration
          shakemap_uz(ia) = max(shakemap_uz(ia),abs(accel(1,iglob)),abs(accel(2,iglob)))
        case (2)
          ! all outer surfaces, using norm of particle displ/veloc/accel vector
          ! saves norm of displacement,velocity and acceleration vector
          ! norm of displacement
          shakemap_ux(ia) = max(shakemap_ux(ia),sqrt(displ(1,iglob)**2 + displ(2,iglob)**2 + displ(3,iglob)**2))
          ! norm of velocity
          shakemap_uy(ia) = max(shakemap_uy(ia),sqrt(veloc(1,iglob)**2 + veloc(2,iglob)**2 + veloc(3,iglob)**2))
          ! norm of acceleration
          shakemap_uz(ia) = max(shakemap_uz(ia),sqrt(accel(1,iglob)**2 + accel(2,iglob)**2 + accel(3,iglob)**2))
        case (3)
          ! geometric mean of PGD, PGV, PGA
          ! only top surface, using horizontal peak-ground value
          gmean_PGD = sqrt( abs(displ(1,iglob) * displ(2,iglob)) )
          gmean_PGV = sqrt( abs(veloc(1,iglob) * veloc(2,iglob)) )
          gmean_PGA = sqrt( abs(accel(1,iglob) * accel(2,iglob)) )
          ! horizontal displacement
          shakemap_ux(ia) = max(shakemap_ux(ia),gmean_PGD)
          ! horizontal velocity
          shakemap_uy(ia) = max(shakemap_uy(ia),gmean_PGV)
          ! horizontal acceleration
          shakemap_uz(ia) = max(shakemap_uz(ia),gmean_PGA)
        end select
      enddo
    else
      ! other element types not supported yet
      call exit_MPI(myrank,'Invalid element for shakemap, only acoustic or elastic elements are supported for now')
    endif

  enddo

  ! saves shakemap only at the end of the simulation
  if (it == NSTEP) call wmo_save_shakemap()

  end subroutine wmo_create_shakemap

!================================================================

  subroutine wmo_get_max_vector_shakemap(ispec,iglob,ia,displ_element,veloc_element,accel_element,MOVIE_TYPE)

  ! put into this separate routine to make compilation faster

  use constants, only: NDIM,NGLLX,NGLLY,NGLLZ,CUSTOM_REAL
  use specfem_par, only: ibool
  use specfem_par_movie, only: shakemap_ux,shakemap_uy,shakemap_uz

  implicit none

  integer,intent(in) :: ispec,iglob,ia,MOVIE_TYPE
  real(kind=CUSTOM_REAL),dimension(NDIM,NGLLX,NGLLY,NGLLZ),intent(in) :: displ_element,veloc_element,accel_element

  ! local parameters
  integer :: i,j,k
  real(kind=CUSTOM_REAL) :: gmean_PGD,gmean_PGV,gmean_PGA

  ! loops over all GLL points from this element
  do k = 1,NGLLZ
    do j = 1,NGLLY
      do i = 1,NGLLX
        ! checks if global point is found
        if (iglob == ibool(i,j,k,ispec)) then
          ! sets shakemap value
          select case (MOVIE_TYPE)
          case (1)
            ! PGD, PGV, PGA
            ! horizontal displacement
            shakemap_ux(ia) = max(shakemap_ux(ia),abs(displ_element(1,i,j,k)),abs(displ_element(2,i,j,k)))
            ! horizontal velocity
            shakemap_uy(ia) = max(shakemap_uy(ia),abs(veloc_element(1,i,j,k)),abs(veloc_element(2,i,j,k)))
            ! horizontal acceleration
            shakemap_uz(ia) = max(shakemap_uz(ia),abs(accel_element(1,i,j,k)),abs(accel_element(2,i,j,k)))
          case (2)
            ! norm of particle displ/veloc/accel vector
            ! norm of displacement
            shakemap_ux(ia) = max(shakemap_ux(ia), &
                  sqrt(displ_element(1,i,j,k)**2 + displ_element(2,i,j,k)**2 + displ_element(3,i,j,k)**2))
            ! norm of velocity
            shakemap_uy(ia) = max(shakemap_uy(ia), &
                  sqrt(veloc_element(1,i,j,k)**2 + veloc_element(2,i,j,k)**2 + veloc_element(3,i,j,k)**2))
            ! norm of acceleration
            shakemap_uz(ia) = max(shakemap_uz(ia), &
                  sqrt(accel_element(1,i,j,k)**2 + accel_element(2,i,j,k)**2 + accel_element(3,i,j,k)**2))
          case (3)
            ! geometric mean of PGD, PGV, PGA
            gmean_PGD = sqrt( abs(displ_element(1,i,j,k) * displ_element(2,i,j,k)) )
            gmean_PGV = sqrt( abs(veloc_element(1,i,j,k) * veloc_element(2,i,j,k)) )
            gmean_PGA = sqrt( abs(accel_element(1,i,j,k) * accel_element(2,i,j,k)) )
            ! horizontal displacement
            shakemap_ux(ia) = max(shakemap_ux(ia),gmean_PGD)
            ! horizontal velocity
            shakemap_uy(ia) = max(shakemap_uy(ia),gmean_PGV)
            ! horizontal acceleration
            shakemap_uz(ia) = max(shakemap_uz(ia),gmean_PGA)
          end select

          ! point found, we are done
          return
        endif
      enddo
    enddo
  enddo

  end subroutine wmo_get_max_vector_shakemap

!================================================================

! not used, left here for reference...
!
!  subroutine wmo_get_max_vector_norm(ispec,iglob,ia, &
!                                        displ_element,veloc_element,accel_element)
!
!  ! put into this separate routine to make compilation faster
!
!  use specfem_par, only: NDIM,ibool
!  use specfem_par_movie
!  implicit none
!
!  integer,intent(in) :: ispec,iglob,ia
!  real(kind=CUSTOM_REAL),dimension(NDIM,NGLLX,NGLLY,NGLLZ),intent(in) :: displ_element,veloc_element,accel_element
!
!  ! local parameters
!  integer :: i,j,k
!
!  ! loops over all GLL points from this element
!  do k=1,NGLLZ
!    do j=1,NGLLY
!      do i=1,NGLLX
!        if (iglob == ibool(i,j,k,ispec)) then
!          ! norm of displacement
!          shakemap_ux(ia) = max(shakemap_ux(ia), &
!                sqrt(displ_element(1,i,j,k)**2 &
!                   + displ_element(2,i,j,k)**2 &
!                   + displ_element(3,i,j,k)**2))
!          ! norm of velocity
!          shakemap_uy(ia) = max(shakemap_uy(ia), &
!                sqrt(veloc_element(1,i,j,k)**2 &
!                   + veloc_element(2,i,j,k)**2 &
!                   + veloc_element(3,i,j,k)**2))
!          ! norm of acceleration
!          shakemap_uz(ia) = max(shakemap_uz(ia), &
!                sqrt(accel_element(1,i,j,k)**2 &
!                   + accel_element(2,i,j,k)**2 &
!                   + accel_element(3,i,j,k)**2))
!
!          ! point found, we are done
!          return
!        endif
!      enddo
!    enddo
!  enddo
!
!  end subroutine wmo_get_max_vector_norm


!================================================================

  subroutine wmo_save_shakemap()

  use specfem_par
  use specfem_par_movie

  implicit none

  ! local parameters
  integer :: ier
  real(kind=CUSTOM_REAL),dimension(1):: dummy

  ! selects routine for file i/o format
  if (HDF5_FOR_MOVIES) then
    call wmo_save_shakemap_hdf5()
    ! all done
    return
  else
    ! binary file
    ! implemented here below, continue
    continue
  endif

  ! main collects
  if (myrank == 0) then
    ! shakemaps
    call gatherv_all_cr(shakemap_ux,nfaces_surface_points, &
                        shakemap_ux_all,nfaces_perproc_surface,faces_surface_offset, &
                        nfaces_surface_glob_points,NPROC)
    call gatherv_all_cr(shakemap_uy,nfaces_surface_points, &
                        shakemap_uy_all,nfaces_perproc_surface,faces_surface_offset, &
                        nfaces_surface_glob_points,NPROC)
    call gatherv_all_cr(shakemap_uz,nfaces_surface_points, &
                        shakemap_uz_all,nfaces_perproc_surface,faces_surface_offset, &
                        nfaces_surface_glob_points,NPROC)
  else
    ! shakemaps
    call gatherv_all_cr(shakemap_ux,nfaces_surface_points, &
                        dummy,nfaces_perproc_surface,faces_surface_offset, &
                        1,NPROC)
    call gatherv_all_cr(shakemap_uy,nfaces_surface_points, &
                        dummy,nfaces_perproc_surface,faces_surface_offset, &
                        1,NPROC)
    call gatherv_all_cr(shakemap_uz,nfaces_surface_points, &
                        dummy,nfaces_perproc_surface,faces_surface_offset, &
                        1,NPROC)
  endif

  ! creates shakemap file
  if (myrank == 0) then
    open(unit=IOUT,file=trim(OUTPUT_FILES)//'/shakingdata',status='unknown',form='unformatted',iostat=ier)
    if (ier /= 0) stop 'error opening file shakingdata'
    write(IOUT) store_val_x_all   ! x coordinates
    write(IOUT) store_val_y_all   ! y coordinates
    write(IOUT) store_val_z_all   ! z coordinates
    write(IOUT) shakemap_ux_all  ! norm of displacement vector
    write(IOUT) shakemap_uy_all  ! norm of velocity vector
    write(IOUT) shakemap_uz_all  ! norm of acceleration vector
    close(IOUT)
  endif

  end subroutine wmo_save_shakemap


!=====================================================================

  subroutine wmo_movie_volume_output()

! outputs movie files for div, curl and velocity

  use specfem_par
  use specfem_par_elastic
  use specfem_par_poroelastic
  use specfem_par_acoustic
  use specfem_par_movie

  implicit none

  ! local parameters
  real(kind=CUSTOM_REAL),dimension(NDIM,NGLLX,NGLLY,NGLLZ) :: vec_element
  integer :: ispec,iglob
#ifdef FORCE_VECTORIZATION
  integer :: ijk
#else
  integer :: i,j,k
#endif

  ! note: we use either displacement or velocity, depending on the Par_file setting of SAVE_DISPLACEMENT,
  !       and store them into the arrays wavefield_x/y/z - the naming of the arrays could be better...
  !
  ! saves wavefield here
  ! note: displacement will show static offset on displacement field for movies,
  !       thus better to have velocity visualized for movies
  wavefield_x(:,:,:,:) = 0._CUSTOM_REAL
  wavefield_y(:,:,:,:) = 0._CUSTOM_REAL
  wavefield_z(:,:,:,:) = 0._CUSTOM_REAL

  if (ACOUSTIC_SIMULATION) then
    ! uses wavefield_x,.. as temporary arrays to store velocity/displacement on all GLL points
    do ispec = 1,NSPEC_AB
      ! only acoustic elements
      if (.not. ispec_is_acoustic(ispec)) cycle

      if (SAVE_DISPLACEMENT) then
        ! calculates displacement
        call compute_gradient_in_acoustic(ispec,potential_acoustic,vec_element)
      else
        ! calculates velocity
        call compute_gradient_in_acoustic(ispec,potential_dot_acoustic,vec_element)
      endif
      wavefield_x(:,:,:,ispec) = vec_element(1,:,:,:)
      wavefield_y(:,:,:,ispec) = vec_element(2,:,:,:)
      wavefield_z(:,:,:,ispec) = vec_element(3,:,:,:)
    enddo

    ! outputs pressure field for purely acoustic simulations
    if (.not. ELASTIC_SIMULATION .and. .not. POROELASTIC_SIMULATION) then
      wavefield_pressure(:,:,:,:) = 0._CUSTOM_REAL
      do ispec = 1,NSPEC_AB
        DO_LOOP_IJK
          iglob = ibool(INDEX_IJK,ispec)
          wavefield_pressure(INDEX_IJK,ispec) = - potential_dot_dot_acoustic(iglob)
        ENDDO_LOOP_IJK
      enddo
    endif
  endif ! acoustic

  if (ELASTIC_SIMULATION .or. POROELASTIC_SIMULATION) then
    ! computes div and curl
    if (ELASTIC_SIMULATION) then
      if (SAVE_DISPLACEMENT) then
        ! calculates divergence and curl of displacement field
        call wmo_movie_div_curl(displ, &
                                div,curl_x,curl_y,curl_z, &
                                wavefield_x,wavefield_y,wavefield_z, &
                                ispec_is_elastic)
      else
        ! calculates divergence and curl of velocity field
        call wmo_movie_div_curl(veloc, &
                                div,curl_x,curl_y,curl_z, &
                                wavefield_x,wavefield_y,wavefield_z, &
                                ispec_is_elastic)
      endif
    endif ! elastic

    ! saves full snapshot data to local disk
    if (POROELASTIC_SIMULATION) then
      if (SAVE_DISPLACEMENT) then
        ! calculates divergence and curl of displacement field
        call wmo_movie_div_curl(displs_poroelastic, &
                                div,curl_x,curl_y,curl_z, &
                                wavefield_x,wavefield_y,wavefield_z, &
                                ispec_is_poroelastic)
      else
        ! calculates divergence and curl of velocity field
        call wmo_movie_div_curl(velocs_poroelastic, &
                                div,curl_x,curl_y,curl_z, &
                                wavefield_x,wavefield_y,wavefield_z, &
                                ispec_is_poroelastic)
      endif
    endif ! poroelastic
  endif

  ! saves movie snapshot
  call wmo_movie_save_volume_snapshot()

  end subroutine wmo_movie_volume_output

!=====================================================================

  subroutine wmo_movie_save_volume_snapshot()

  use specfem_par
  use specfem_par_movie

  implicit none

  ! local parameters
  integer :: ier
  character(len=3) :: channel
  character(len=1) :: compx,compy,compz
  character(len=MAX_STRING_LEN) :: outputname

  ! selects routine for file i/o format
  if (HDF5_FOR_MOVIES) then
    call wmo_movie_save_volume_snapshot_hdf5()
    ! all done
    return
  else
    ! binary file
    ! implemented here below, continue
    continue
  endif

  ! gets component characters: X/Y/Z or E/N/Z
  call write_channel_name(1,channel)
  compx(1:1) = channel(3:3) ! either X or E
  call write_channel_name(2,channel)
  compy(1:1) = channel(3:3) ! either Y or N
  call write_channel_name(3,channel)
  compz(1:1) = channel(3:3) ! Z

  ! saves wavefields to file
  if (SAVE_DISPLACEMENT) then
    ! displacement field
    write(outputname,"('/proc',i6.6,'_displ_',a1,'_it',i6.6,'.bin')") myrank,compx,it
    open(unit=IOUT,file=trim(LOCAL_PATH)//trim(outputname),status='unknown',form='unformatted',iostat=ier)
    if (ier /= 0) stop 'error opening file movie output displ x'
    write(IOUT) wavefield_x
    close(IOUT)

    write(outputname,"('/proc',i6.6,'_displ_',a1,'_it',i6.6,'.bin')") myrank,compy,it
    open(unit=IOUT,file=trim(LOCAL_PATH)//trim(outputname),status='unknown',form='unformatted',iostat=ier)
    if (ier /= 0) stop 'error opening file movie output displ y'
    write(IOUT) wavefield_y
    close(IOUT)

    write(outputname,"('/proc',i6.6,'_displ_',a1,'_it',i6.6,'.bin')") myrank,compz,it
    open(unit=IOUT,file=trim(LOCAL_PATH)//trim(outputname),status='unknown',form='unformatted',iostat=ier)
    if (ier /= 0) stop 'error opening file movie output displ z'
    write(IOUT) wavefield_z
    close(IOUT)
  else
    ! velocity
    write(outputname,"('/proc',i6.6,'_velocity_',a1,'_it',i6.6,'.bin')") myrank,compx,it
    open(unit=IOUT,file=trim(LOCAL_PATH)//trim(outputname),status='unknown',form='unformatted',iostat=ier)
    if (ier /= 0) stop 'error opening file movie output velocity x'
    write(IOUT) wavefield_x
    close(IOUT)

    write(outputname,"('/proc',i6.6,'_velocity_',a1,'_it',i6.6,'.bin')") myrank,compy,it
    open(unit=IOUT,file=trim(LOCAL_PATH)//trim(outputname),status='unknown',form='unformatted',iostat=ier)
    if (ier /= 0) stop 'error opening file movie output velocity y'
    write(IOUT) wavefield_y
    close(IOUT)

    write(outputname,"('/proc',i6.6,'_velocity_',a1,'_it',i6.6,'.bin')") myrank,compz,it
    open(unit=IOUT,file=trim(LOCAL_PATH)//trim(outputname),status='unknown',form='unformatted',iostat=ier)
    if (ier /= 0) stop 'error opening file movie output velocity z'
    write(IOUT) wavefield_z
    close(IOUT)
  endif

  ! saves div/curl to file
  if (ELASTIC_SIMULATION .or. POROELASTIC_SIMULATION) then
    ! div and curl on elemental level
    ! writes our divergence
    write(outputname,"('/proc',i6.6,'_div_it',i6.6,'.bin')") myrank,it
    open(unit=IOUT,file=trim(LOCAL_PATH)//trim(outputname),status='unknown',form='unformatted',iostat=ier)
    if (ier /= 0) stop 'error opening file div_it'
    write(IOUT) div
    close(IOUT)

    ! writes out curl
    write(outputname,"('/proc',i6.6,'_curl_',a1,'_it',i6.6,'.bin')") myrank,compx,it
    open(unit=IOUT,file=trim(LOCAL_PATH)//trim(outputname),status='unknown',form='unformatted',iostat=ier)
    if (ier /= 0) stop 'error opening file curl_x_it '
    write(IOUT) curl_x
    close(IOUT)

    write(outputname,"('/proc',i6.6,'_curl_',a1,'_it',i6.6,'.bin')") myrank,compy,it
    open(unit=IOUT,file=trim(LOCAL_PATH)//trim(outputname),status='unknown',form='unformatted',iostat=ier)
    if (ier /= 0) stop 'error opening file curl_y_it'
    write(IOUT) curl_y
    close(IOUT)

    write(outputname,"('/proc',i6.6,'_curl_',a1,'_it',i6.6,'.bin')") myrank,compz,it
    open(unit=IOUT,file=trim(LOCAL_PATH)//trim(outputname),status='unknown',form='unformatted',iostat=ier)
    if (ier /= 0) stop 'error opening file curl_z_it'
    write(IOUT) curl_z
    close(IOUT)

    ! writes out div and curl on global points
    write(outputname,"('/proc',i6.6,'_div_glob_it',i6.6,'.bin')") myrank,it
    open(unit=IOUT,file=trim(LOCAL_PATH)//trim(outputname),status='unknown',form='unformatted',iostat=ier)
    if (ier /= 0) stop 'error opening file div_glob'
    write(IOUT) div_glob
    close(IOUT)

    ! writes out stress tensor
    if (MOVIE_VOLUME_STRESS) then
      ! stress tensor on elemental level
      write(outputname,"('/proc',i6.6,'_stress_xx_it',i6.6,'.bin')") myrank,it
      open(unit=IOUT,file=trim(LOCAL_PATH)//trim(outputname),status='unknown',form='unformatted',iostat=ier)
      if (ier /= 0) stop 'error opening file stress_xx_it'
      write(IOUT) stress_xx
      close(IOUT)

      write(outputname,"('/proc',i6.6,'_stress_yy_it',i6.6,'.bin')") myrank,it
      open(unit=IOUT,file=trim(LOCAL_PATH)//trim(outputname),status='unknown',form='unformatted',iostat=ier)
      if (ier /= 0) stop 'error opening file stress_yy_it'
      write(IOUT) stress_yy
      close(IOUT)

      write(outputname,"('/proc',i6.6,'_stress_zz_it',i6.6,'.bin')") myrank,it
      open(unit=IOUT,file=trim(LOCAL_PATH)//trim(outputname),status='unknown',form='unformatted',iostat=ier)
      if (ier /= 0) stop 'error opening file stress_zz_it'
      write(IOUT) stress_zz
      close(IOUT)

      write(outputname,"('/proc',i6.6,'_stress_xy_it',i6.6,'.bin')") myrank,it
      open(unit=IOUT,file=trim(LOCAL_PATH)//trim(outputname),status='unknown',form='unformatted',iostat=ier)
      if (ier /= 0) stop 'error opening file stress_xy_it'
      write(IOUT) stress_xy
      close(IOUT)

      write(outputname,"('/proc',i6.6,'_stress_xz_it',i6.6,'.bin')") myrank,it
      open(unit=IOUT,file=trim(LOCAL_PATH)//trim(outputname),status='unknown',form='unformatted',iostat=ier)
      if (ier /= 0) stop 'error opening file stress_xz_it'
      write(IOUT) stress_xz
      close(IOUT)

      write(outputname,"('/proc',i6.6,'_stress_yz_it',i6.6,'.bin')") myrank,it
      open(unit=IOUT,file=trim(LOCAL_PATH)//trim(outputname),status='unknown',form='unformatted',iostat=ier)
      if (ier /= 0) stop 'error opening file stress_yz_it'
      write(IOUT) stress_yz
      close(IOUT)
    endif
  endif

  ! saves pressure to file
  if (ACOUSTIC_SIMULATION) then
    ! outputs pressure
    if (.not. ELASTIC_SIMULATION .and. .not. POROELASTIC_SIMULATION) then
      write(outputname,"('/proc',i6.6,'_pressure_it',i6.6,'.bin')")myrank,it
      open(unit=IOUT,file=trim(LOCAL_PATH)//trim(outputname),status='unknown',form='unformatted',iostat=ier)
      if (ier /= 0) stop 'error opening file movie output pressure'
      write(IOUT) wavefield_pressure
      close(IOUT)
    endif
  endif

  end subroutine wmo_movie_save_volume_snapshot

!=====================================================================

  subroutine wmo_movie_div_curl(veloc, &
                                div,curl_x,curl_y,curl_z, &
                                wavefield_x,wavefield_y,wavefield_z, &
                                ispec_is)

! calculates div, curl and wavefield

  use constants

  use specfem_par, only: NSPEC_AB,NGLOB_AB,ibool,hprime_xx,hprime_yy,hprime_zz, &
    xixstore,xiystore,xizstore,etaxstore,etaystore,etazstore, &
    gammaxstore,gammaystore,gammazstore,irregular_element_number, &
    xix_regular

  use specfem_par_movie, only: div_glob,valence_glob

  implicit none


  ! velocity field
  real(kind=CUSTOM_REAL),dimension(NDIM,NGLOB_AB),intent(in) :: veloc

  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLY,NGLLZ,NSPEC_AB),intent(out) :: div, curl_x, curl_y, curl_z
  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLY,NGLLZ,NSPEC_AB),intent(inout) :: wavefield_x,wavefield_y,wavefield_z
  logical,dimension(NSPEC_AB),intent(in) :: ispec_is

  ! local parameters
  real(kind=CUSTOM_REAL), dimension(NDIM,NGLLX,NGLLY,NGLLZ) :: veloc_element
  real(kind=CUSTOM_REAL), dimension(NGLLX,NGLLY,NGLLZ) :: dvxdxl,dvxdyl, &
                                dvxdzl,dvydxl,dvydyl,dvydzl,dvzdxl,dvzdyl,dvzdzl
  real(kind=CUSTOM_REAL) xixl,xiyl,xizl,etaxl,etayl,etazl,gammaxl,gammayl,gammazl
  real(kind=CUSTOM_REAL) hp1,hp2,hp3
  real(kind=CUSTOM_REAL) tempx1l,tempx2l,tempx3l
  real(kind=CUSTOM_REAL) tempy1l,tempy2l,tempy3l
  real(kind=CUSTOM_REAL) tempz1l,tempz2l,tempz3l
  integer :: ispec,ispec_irreg,i,j,k,l,iglob

  ! initializes
  div_glob(:) = 0.0_CUSTOM_REAL
  valence_glob(:) = 0

  ! loops over elements
  do ispec = 1,NSPEC_AB
    ! only selected elements
    if (.not. ispec_is(ispec)) cycle

    ispec_irreg = irregular_element_number(ispec)

    ! loads veloc to local element
    do k = 1,NGLLZ
      do j = 1,NGLLY
        do i = 1,NGLLX
          iglob = ibool(i,j,k,ispec)
          veloc_element(1,i,j,k) = veloc(1,iglob)
          veloc_element(2,i,j,k) = veloc(2,iglob)
          veloc_element(3,i,j,k) = veloc(3,iglob)
        enddo
      enddo
    enddo

    ! calculates divergence and curl of velocity field
    do k = 1,NGLLZ
      do j = 1,NGLLY
        do i = 1,NGLLX
          tempx1l = 0._CUSTOM_REAL
          tempx2l = 0._CUSTOM_REAL
          tempx3l = 0._CUSTOM_REAL

          tempy1l = 0._CUSTOM_REAL
          tempy2l = 0._CUSTOM_REAL
          tempy3l = 0._CUSTOM_REAL

          tempz1l = 0._CUSTOM_REAL
          tempz2l = 0._CUSTOM_REAL
          tempz3l = 0._CUSTOM_REAL

!! DK DK Oct 2018: we could (and should) use the Deville matrix products instead here
!! DK DK Oct 2018: we could (and should) use the Deville matrix products instead here
!! DK DK Oct 2018: we could (and should) use the Deville matrix products instead here
!! DK DK Oct 2018: we could (and should) use the Deville matrix products instead here
!! DK DK Oct 2018: we could (and should) use the Deville matrix products instead here
!! DK DK Oct 2018: we could (and should) use the Deville matrix products instead here
!! DK DK Oct 2018: we could (and should) use the Deville matrix products instead here
!! DK DK Oct 2018: we could (and should) use the Deville matrix products instead here
!! DK DK Oct 2018: we could (and should) use the Deville matrix products instead here
!! DK DK Oct 2018: we could (and should) use the Deville matrix products instead here
!! DK DK Oct 2018: we could (and should) use the Deville matrix products instead here
!! DK DK Oct 2018: we could (and should) use the Deville matrix products instead here
!! DK DK Oct 2018: we could (and should) use the Deville matrix products instead here

!! DK DK Oct 2018: however this curl and div calculation routine for movies is almost never called
!! DK DK Oct 2018: however this curl and div calculation routine for movies is almost never called
!! DK DK Oct 2018: however this curl and div calculation routine for movies is almost never called
!! DK DK Oct 2018: however this curl and div calculation routine for movies is almost never called
!! DK DK Oct 2018: however this curl and div calculation routine for movies is almost never called
!! DK DK Oct 2018: however this curl and div calculation routine for movies is almost never called
!! DK DK Oct 2018: however this curl and div calculation routine for movies is almost never called
!! DK DK Oct 2018: however this curl and div calculation routine for movies is almost never called
!! DK DK Oct 2018: however this curl and div calculation routine for movies is almost never called
!! DK DK Oct 2018: however this curl and div calculation routine for movies is almost never called
!! DK DK Oct 2018: however this curl and div calculation routine for movies is almost never called

          do l = 1,NGLLX
            hp1 = hprime_xx(i,l)
            tempx1l = tempx1l + veloc_element(1,l,j,k)*hp1
            tempy1l = tempy1l + veloc_element(2,l,j,k)*hp1
            tempz1l = tempz1l + veloc_element(3,l,j,k)*hp1

            hp2 = hprime_yy(j,l)
            tempx2l = tempx2l + veloc_element(1,i,l,k)*hp2
            tempy2l = tempy2l + veloc_element(2,i,l,k)*hp2
            tempz2l = tempz2l + veloc_element(3,i,l,k)*hp2

            hp3 = hprime_zz(k,l)
            tempx3l = tempx3l + veloc_element(1,i,j,l)*hp3
            tempy3l = tempy3l + veloc_element(2,i,j,l)*hp3
            tempz3l = tempz3l + veloc_element(3,i,j,l)*hp3
          enddo

          if (ispec_irreg /= 0) then ! irregular element
            ! get derivatives of ux, uy and uz with respect to x, y and z
            xixl = xixstore(i,j,k,ispec_irreg)
            xiyl = xiystore(i,j,k,ispec_irreg)
            xizl = xizstore(i,j,k,ispec_irreg)
            etaxl = etaxstore(i,j,k,ispec_irreg)
            etayl = etaystore(i,j,k,ispec_irreg)
            etazl = etazstore(i,j,k,ispec_irreg)
            gammaxl = gammaxstore(i,j,k,ispec_irreg)
            gammayl = gammaystore(i,j,k,ispec_irreg)
            gammazl = gammazstore(i,j,k,ispec_irreg)

            dvxdxl(i,j,k) = xixl*tempx1l + etaxl*tempx2l + gammaxl*tempx3l
            dvxdyl(i,j,k) = xiyl*tempx1l + etayl*tempx2l + gammayl*tempx3l
            dvxdzl(i,j,k) = xizl*tempx1l + etazl*tempx2l + gammazl*tempx3l

            dvydxl(i,j,k) = xixl*tempy1l + etaxl*tempy2l + gammaxl*tempy3l
            dvydyl(i,j,k) = xiyl*tempy1l + etayl*tempy2l + gammayl*tempy3l
            dvydzl(i,j,k) = xizl*tempy1l + etazl*tempy2l + gammazl*tempy3l

            dvzdxl(i,j,k) = xixl*tempz1l + etaxl*tempz2l + gammaxl*tempz3l
            dvzdyl(i,j,k) = xiyl*tempz1l + etayl*tempz2l + gammayl*tempz3l
            dvzdzl(i,j,k) = xizl*tempz1l + etazl*tempz2l + gammazl*tempz3l

          else ! regular element

            dvxdxl(i,j,k) = xix_regular*tempx1l
            dvxdyl(i,j,k) = xix_regular*tempx2l
            dvxdzl(i,j,k) = xix_regular*tempx3l

            dvydxl(i,j,k) = xix_regular*tempy1l
            dvydyl(i,j,k) = xix_regular*tempy2l
            dvydzl(i,j,k) = xix_regular*tempy3l

            dvzdxl(i,j,k) = xix_regular*tempz1l
            dvzdyl(i,j,k) = xix_regular*tempz2l
            dvzdzl(i,j,k) = xix_regular*tempz3l

          endif

        enddo
      enddo
    enddo

    do k = 1,NGLLZ
      do j = 1,NGLLY
        do i = 1,NGLLX

          ! divergence \nabla \cdot \bf{v}
          div(i,j,k,ispec) = dvxdxl(i,j,k) + dvydyl(i,j,k) + dvzdzl(i,j,k)

          ! curl
          curl_x(i,j,k,ispec) = dvzdyl(i,j,k) - dvydzl(i,j,k)
          curl_y(i,j,k,ispec) = dvxdzl(i,j,k) - dvzdxl(i,j,k)
          curl_z(i,j,k,ispec) = dvydxl(i,j,k) - dvxdyl(i,j,k)

          ! velocity or displacement field
          iglob = ibool(i,j,k,ispec)
          wavefield_x(i,j,k,ispec) = veloc_element(1,i,j,k)
          wavefield_y(i,j,k,ispec) = veloc_element(2,i,j,k)
          wavefield_z(i,j,k,ispec) = veloc_element(3,i,j,k)

          valence_glob(iglob) = valence_glob(iglob)+1
          div_glob(iglob) = div_glob(iglob) + div(i,j,k,ispec)
        enddo
      enddo
    enddo
  enddo !NSPEC_AB

  do i = 1,NGLOB_AB
    ! checks if point has a contribution
    ! note: might not be the case for points in acoustic elements
    if (valence_glob(i) /= 0) then
      ! averages by number of contributions
      div_glob(i) = div_glob(i)/valence_glob(i)
    endif
  enddo

  end subroutine wmo_movie_div_curl

