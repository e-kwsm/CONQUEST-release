! -*- mode: F90; mode: font-lock; column-number-mode: true; vc-back-end: CVS -*-
! ------------------------------------------------------------------------------
! $Id$
! ------------------------------------------------------------------------------
! Module initialisation
! ------------------------------------------------------------------------------
! Code area 1: initialisation
! ------------------------------------------------------------------------------

!!****h* Conquest/initialisation *
!!  NAME
!!   initialisation
!!  PURPOSE
!!   Hold initialisation routines
!!  AUTHOR
!!   D. R. Bowler
!!  CREATION DATE
!!   2006/10/16 (bringing together existing routines)
!!  MODIFICATION HISTORY
!!   2008/02/06 08:06 dave
!!    Changed for output to file not stdout
!!   2008/05/15 ast
!!    Added some timers
!!  SOURCE
!!
module initialisation

  use datatypes
  use global_module, ONLY: io_lun
  use timer_stdclocks_module, ONLY: start_timer,stop_timer,tmr_std_initialisation,tmr_std_densitymat,tmr_std_matrices
  use timer_module, ONLY: init_timing_system

  implicit none

  ! RCS tag for object file identification
  character(len=80), save, private :: RCSid = "$Id$"

!!***

contains

!!****f* initialisation/initialise *
!!
!!  NAME 
!!   initialise
!!  USAGE
!! 
!!  PURPOSE
!!   Controls initialisation process for a run - reads in the
!!   parameters and writes out information for the user, performs
!!   various tedious setting up operations on pseudopotentials, 
!!   grids and matrices, sorts out the initial support functions
!!   and finally gets a self-consistent Hamiltonian and potential.
!!   At that point, the job is ready to go !
!!  INPUTS
!! 
!! 
!!  USES
!!   common, datatypes, dimens, GenComms, initial_read, matrix_data
!!  AUTHOR
!!   D.R.Bowler
!!  CREATION DATE
!!   November 1998
!!  MODIFICATION HISTORY
!!   25/05/2001 dave
!!    ROBODoc header, indenting and stripping subroutine calls
!!   29/05/2001 dave
!!    Stripped subroutine call
!!   08/06/2001 dave
!!    Added RCS Id and Log tags and GenComms for my_barrier
!!   13/06/2001 dave
!!    Changed call to set_up for init_pseudo
!!   10/05/2002 dave
!!    Added use statement for initial_read to get read_and_write
!!   05/09/2002 mjg & drb 
!!    Added ionic data calls and uses
!!   15:58, 25/09/2002 mjg & drb 
!!    Added careful flags for checking to see if atomic densities have been 
!!    specified, and whether the user wants to initialise the initial charge
!!    density from the initial K, or from atomic densities, or hasn't told us
!!    at all !
!!   15:24, 27/02/2003 drb & tm 
!!    Moved flag_no_atomic_densities into density_module
!!   11:03, 24/03/2003 drb 
!!    Simplified call to read_and_write, removed initial_phi
!!   10:09, 13/02/2006 drb 
!!    Removed all explicit references to data_ variables and rewrote in terms of new 
!!    matrix routines
!!   2008/05/15 ast
!!    Added some timers
!!  SOURCE
!!
  subroutine initialise(vary_mu, fixed_potential, number_of_bands, mu, total_energy)

    use datatypes
    use GenComms, ONLY: inode, ionode, my_barrier
    use initial_read, ONLY: read_and_write
    use ionic_data, ONLY : get_ionic_data
    use density_module, ONLY: flag_no_atomic_densities
    use memory_module, ONLY: init_reg_mem

    implicit none

    ! Passed variables
    logical :: vary_mu, find_chdens, fixed_potential

    character(len=40) :: output_file

    real(double) :: mu
    real(double) :: number_of_bands, total_energy

    ! Local variables
    logical :: start, start_L
    logical :: read_phi

    character(len=40) :: restart_file

    call init_timing_system(inode)
    call start_timer(tmr_std_initialisation)

    ! Read input
    call init_reg_mem
    call read_and_write(start, start_L,&
         inode, ionode, restart_file, vary_mu, mu,&
         find_chdens, read_phi, number_of_bands)

    ! Call routines to read or make data for isolated ions
    flag_no_atomic_densities = .false.
    call get_ionic_data(inode,ionode,flag_no_atomic_densities)
    if(flag_no_atomic_densities.AND.(.NOT.find_chdens)) then
       if(inode==ionode) write(io_lun,*) 'No initial charge density specified - building from initial K'
       find_chdens = .true.
    end if

    call set_up(find_chdens, number_of_bands)

    call my_barrier

    call initial_phis( mu, restart_file, read_phi, vary_mu, start)

    call initial_H( start, start_L, find_chdens, fixed_potential, vary_mu, number_of_bands, mu, total_energy)

    call stop_timer(tmr_std_initialisation)
    return
  end subroutine initialise
!!***

!!****f* initialisation/set_up *
!!
!!  NAME 
!!   set_up
!!  USAGE
!! 
!!  PURPOSE
!!   Performs various calls needed to set up the calculation
!!   like pseudopotentials and grids
!!  INPUTS
!! 
!! 
!!  USES
!! 
!!  AUTHOR
!!   D.R.Bowler
!!  CREATION DATE
!!   November 1998 ?
!!  MODIFICATION HISTORY
!!   25/05/2001 dave
!!    Stripped various subroutine calls, added ROBODoc header
!!    Stripped overall subroutine call
!!   11/06/2001 dave
!!    Added RCS Id and Log tags and GenComms
!!   13/06/2001 dave
!!    Changed to use pseudopotential_data for init_pseudo and
!!    passed core_correction
!!   15:58, 25/09/2002 mjg & drb 
!!    Added set_density for initialising charge density
!!   11:51, 04/02/2003 drb 
!!    Removed cq_exit from GenComms use
!!   13:11, 22/10/2003 mjg & drb 
!!    Changed set_ewald call to read appropriate flag and call old or new routine
!!   11:59, 12/11/2004 dave 
!!    Changed to get nodes from GenComms not common
!!  SOURCE
!!
  subroutine set_up(find_chdens, number_of_bands)

    use datatypes
    use global_module, ONLY: iprint_init, flag_read_blocks, x_atom_cell, y_atom_cell, z_atom_cell, ni_in_cell, &
         area_init, area_index
    use memory_module, ONLY: reg_alloc_mem, reg_dealloc_mem, type_dbl, type_int
    use group_module, ONLY: parts
    use primary_module, ONLY : bundle
    use cover_module, ONLY : BCS_parts, make_cs, make_iprim, send_ncover
    use mult_module, ONLY: immi
    use construct_module
    use matrix_data, ONLY: rcut, Lrange, Srange, mx_matrices
    use ewald_module, ONLY: set_ewald, mikes_set_ewald, flag_old_ewald
    use atoms, ONLY: distribute_atoms
    use dimens, ONLY: n_grid_x, n_grid_y, n_grid_z, r_core_squared,&
         r_h, r_super_x, r_super_y, r_super_z, RadiusSupport, n_my_grid_points
    use fft_module,ONLY: set_fft_map, fft3
    use GenComms, ONLY: cq_abort, my_barrier, inode, ionode
    use pseudopotential_data, ONLY: init_pseudo
    ! Troullier-Martin pseudos    15/11/2002 TM
    use pseudo_tm_module, ONLY: init_pseudo_tm
    use pseudopotential_common, ONLY: pseudo_type, OLDPS, SIESTA, STATE, ABINIT, core_correction, pseudopotential
    ! Troullier-Martin pseudos    15/11/2002 TM
    use density_module, ONLY: set_density, density
    use block_module, ONLY : nx_in_block,ny_in_block,nz_in_block, n_pts_in_block, &
         set_blocks_from_new, set_blocks_from_old, set_domains, n_blocks
    use grid_index, ONLY: grid_point_x, grid_point_y, grid_point_z, grid_point_block, grid_point_position
    use primary_module, ONLY: domain
    use group_module, ONLY : blocks
    use io_module, ONLY: read_blocks
    use functions_on_grid, ONLY: associate_fn_on_grid
    use potential_module, ONLY: potential
    use maxima_module, ONLY: maxngrid
    use blip, ONLY: Extent
    use species_module, ONLY: n_species
    use angular_coeff_routines, ONLY: set_fact, set_prefac, set_prefac_real

    implicit none

    ! Passed variables
    logical :: find_chdens 

    real(double) :: number_of_bands

    ! Local variables
    complex(double_cplx), allocatable, dimension(:) :: chdenr 
    integer :: i, stat, spec
    integer :: xextent, yextent, zextent
    real(double) :: rcut_BCS  !TM 26/Jun/2003

    integer :: iblock, ipoint,igrid,ix,iy,iz
    real(double) :: xblock,yblock,zblock,dcellx_block,dcelly_block,dcellz_block
    real(double) :: dx,dy,dz,dcellx_grid,dcelly_grid,dcellz_grid

    ! Set organisation of blocks of grid-points.
    ! set_blocks determines the number of blocks on this node,
    ! and makes a list of these blocks.    
    if(flag_read_blocks) then
       call read_blocks(blocks)
    else
       call set_blocks_from_old( n_grid_x, n_grid_y, n_grid_z )
    endif
    call set_blocks_from_new()
    ! Allocate ? 
    !call set_blocks(inode, ionode)
    if (inode==ionode.AND.iprint_init>1) write(io_lun,*) 'Completed set_blocks()'
    n_my_grid_points = n_blocks*n_pts_in_block
    !allocate(grid_point_x(n_my_grid_points),grid_point_y(n_my_grid_points),grid_point_z(n_my_grid_points), &
    !     grid_point_block(n_my_grid_points),grid_point_position(n_my_grid_points),STAT=stat)
    allocate(grid_point_x(maxngrid),grid_point_y(maxngrid),grid_point_z(maxngrid), &
         grid_point_block(maxngrid),grid_point_position(maxngrid),STAT=stat)
    if(stat/=0) call cq_abort("Error allocating grid_point variables: ",maxngrid,stat)
    call reg_alloc_mem(area_index,5*maxngrid,type_int)
    ! Construct list of grid-points in each domain (i.e. grid-points belonging
    ! to each node). In present version, grid-points are organised into
    ! blocks, with each node responsible for a cluster of blocks.
    call set_domains( inode)
    allocate(density(maxngrid), potential(maxngrid), pseudopotential(maxngrid), STAT=stat)
    if(stat/=0) call cq_abort("Error allocating grids: ",maxngrid,stat)
    call reg_alloc_mem(area_index,3*maxngrid,type_dbl)
    call my_barrier()
    if (inode==ionode.AND.iprint_init>1) write(io_lun,*) 'Completed set_domains()'

    do spec = 1, n_species
       xextent = int((RadiusSupport(spec)*n_grid_x/r_super_x)+0.5)
       yextent = int((RadiusSupport(spec)*n_grid_y/r_super_y)+0.5)
       zextent = int((RadiusSupport(spec)*n_grid_z/r_super_z)+0.5)
       Extent(spec) = MAX(xextent,MAX(yextent,zextent))
       if(inode==ionode.AND.iprint_init>2) write(io_lun,*) 'Extent is: ',Extent(spec)
    end do
    ! Sorts out which processor owns which atoms
    call distribute_atoms(inode, ionode)
    call my_barrier
    if(inode==ionode.AND.iprint_init>1) write(io_lun,*) 'Completed distribute_atoms()'
    ! Create a covering set
    call my_barrier
    !Define rcut_BCS  !TM 26/Jun/2003
    rcut_BCS= 2.0_double*rcut(Lrange)+rcut(Srange)
    do i=1, mx_matrices
       if(rcut_BCS < rcut(i)) rcut_BCS= rcut(i)
    enddo !  i=1, mx_matrices
    if(inode==ionode.AND.iprint_init>1) write(io_lun,*) ' rcut for BCS_parts =',rcut_BCS

    call make_cs(inode-1,rcut_BCS, BCS_parts,parts,bundle,ni_in_cell,x_atom_cell, y_atom_cell, z_atom_cell)
    call my_barrier
    call make_iprim(BCS_parts,bundle,inode-1)
    call send_ncover(BCS_parts, inode)
    call my_barrier
    if(inode==ionode.AND.iprint_init>1) &
         write(io_lun,*) 'Made covering set for matrix multiplications'

    ! Create all of the indexing required to perform matrix multiplications
    ! at a later point. This routine also identifies all the density
    ! matrix range interactions and hamiltonian range interactions
    ! associated with any atom being handled by this processor.
    call immi(parts, bundle, BCS_parts, inode)
    if(inode==ionode.AND.iprint_init>1) write(io_lun,*) 'Completed immi()'

    ! set up all the data block by block for atoms overlapping any 
    ! point on block and similar
    !call set_blocks_from_old(                                       &
    !     in_block_x, in_block_y, in_block_z, n_grid_x, n_grid_y, n_grid_z, &
    !     inode, ionode, NODES)
    call setgrid(inode-1,r_core_squared,r_h)

    call my_barrier()
    if (inode==ionode.AND.iprint_init>1) write(io_lun,*) 'Completed set_grid()'

    call associate_fn_on_grid
    call my_barrier()
    if (inode==ionode.AND.iprint_init>1) write(io_lun,*) 'Completed associate_fn_on_grid()'

    ! The FFT requires the data to be reorganised into columns parallel to
    ! each axis in turn. The data for this organisation is help in map.inc,
    ! and is initialised by set_fft_map.
    !
    ! Thee FFT calls themselves require value tables, which are held in
    ! ffttable.inc, and are initialised by calling fft3 with isign=0.
    call set_fft_map ( )
    density = 0.0_double
    allocate(chdenr(maxngrid),STAT=stat)
    if(stat/=0) call cq_abort("Error allocating chdenr: ",maxngrid,stat)
    call reg_alloc_mem(area_init,maxngrid,type_dbl)
    call fft3( density, chdenr, maxngrid, 0 )
    deallocate(chdenr)
    if(stat/=0) call cq_abort("Error deallocating chdenr: ",maxngrid,stat)
    call reg_dealloc_mem(area_init,maxngrid,type_dbl)
    call my_barrier()
    if (inode==ionode.AND.iprint_init>1) write(io_lun,*) 'Completed fft init'

    ! set up the Ewald sumation: find out how many superlatices 
    ! in the real space sum and how many reciprocal latice vectors in the
    ! reciprocal space sum are needed for a given energy tolerance. In the
    ! future the tolerance will be set by the user, but right now it is 
    ! set as a parameter in set_ewald, and its value is 1.0d-5.
    if(flag_old_ewald) then
       call set_ewald(inode, ionode)
    else
       call mikes_set_ewald(inode,ionode)
    end if
    ! +++
    call my_barrier
    if(inode==ionode.AND.iprint_init>1) write(io_lun,*) 'Completed set_ewald()'

    ! external potential - first set up angular momentum bits
    call set_fact
    call set_prefac
    call set_prefac_real
    !  TM's pseudo or not : 15/11/2002 TM
    select case(pseudo_type) 
    case(OLDPS)
       call init_pseudo(number_of_bands, core_correction)
    case(SIESTA)
       call init_pseudo_tm(core_correction)
    case(ABINIT)
       call init_pseudo_tm(core_correction)
    end select
    if(.NOT.find_chdens) call set_density
    if(inode==ionode.AND.iprint_init>1) write(io_lun,*) 'Done init_pseudo '

    return
  end subroutine set_up
!!***

!!****f* initialisation/initial_phis *
!!
!!  NAME 
!!   initial_phis
!!  USAGE
!! 
!!  PURPOSE
!!   Provides initial values for the blip coefficients
!!   representing the support functions. Two ways of
!!   doing this are provided, these ways being specified
!!   by the character-valued variable init_blip_flag, as follows:
!!
!!    init_blip_flag = 'gauss': blips coeffs set as values of a Gaussian
!!      function at the distance of each blip from the atom position.
!!      Can only be used if there are four supports on every atom,
!!      in which case the supports have the form of an s-function
!!      and three p-functions. The Gaussian exponents are alph and beta
!!    (atomic units). This way of intitiating blip coefficients is
!!      a relic of the very early history of Conquest, and its
!!      use is strongly discouraged. Don't put init_blip_flag = 0
!!      unless you have thought very carefully about why you
!!      need to do this.
!!
!!    init_blip_flag = 'pao': blip coeffs set to give best fit to
!!      support functions represented as a given linear combination
!!      of pseudo-atomic orbitals (PAO's). The PAO data itself
!!      is held in the module pao_format, and the PAO representations
!!      of support functions in the module support_spec_format.
!!
!!   These two ways of initiating the blip coeffs are implemented
!!   by calls to the subroutines:
!!
!!    init_blip_flag = 'gauss': gauss2blip
!!    init_blip_flag = 'pao': make_blips_from_paos
!!
!!  INPUTS
!! 
!! 
!!  USES
!! 
!!  AUTHOR
!!   D.R.Bowler
!!  CREATION DATE
!!   Probably late 1998
!!  MODIFICATION HISTORY
!!   28/05/2001 dave
!!    ROBODoc header, stripped normalise_support call
!!
!!   11/06/2001 dave
!!    Added RCS Id and Log tags and GenComms
!!
!!   13/06/02 mjg
!!    Rewritten to allow 2 ways of initiation (see above PURPOSE)
!!   15:17, 04/02/2003 drb 
!!    Added call to do on-site S matrix elements analytically
!!   11:04, 24/03/2003 drb 
!!    Removed call to interp_phi
!!   15:44, 08/04/2003 drb 
!!    Added another blip_to_support and get_matrix_elements after normalisation to ensure correctly 
!!    normalised blips used
!!   14:41, 29/07/2003 drb 
!!    Small, safe changes: no call to get_onsite_S until fixed, and normalisation based on NUMERICAL integration
!!   08:32, 2003/09/22 dave
!!    Changed to not do blip stuff for PAO basis set
!!   14:05, 22/09/2003 drb 
!!    Added test for division by zero
!!   11:02, 23/09/2003 drb 
!!    Bug fix to write statement
!!   12:58, 31/10/2003 drb 
!!    Added NLPF call for generating SP matrix from PAOs
!!   11:40, 12/11/2004 dave 
!!    Removed inappropriate common variables
!!   10:09, 13/02/2006 drb 
!!    Removed all explicit references to data_ variables and rewrote in terms of new 
!!    matrix routines
!!   2006/03/06 05:17 dave
!!    Tidied call and passed variables
!!   2006/09/13 07:57 dave
!!    Changed to get number of coefficients for blips from support_function structure 
!!   2007/05/01 08:31 dave
!!    Changed start_blip into read_option for unified naming
!!  SOURCE
!!
  subroutine initial_phis( mu, restart_file, read_phi, vary_mu, start)

    use datatypes
    use blip, ONLY: init_blip_flag, make_pre, set_blip_index, gauss2blip
    use blip_grid_transform_module, ONLY: blip_to_support_new
    use calc_matrix_elements_module, ONLY: get_matrix_elements_new
    use dimens, ONLY: grid_point_volume, r_h
    !use fdf, ONLY : fdf_boolean
    use GenComms, ONLY: cq_abort, my_barrier, gcopy, inode, ionode
    use global_module, ONLY: iprint_init, flag_basis_set, blips, PAOs
    use matrix_data, ONLY : Srange,mat
    use numbers, ONLY: zero, very_small, one
    use pao2blip, ONLY: make_blips_from_paos
    use primary_module , ONLY : bundle
    use set_bucket_module, ONLY : rem_bucket
    use species_module, ONLY: n_species
    use io_module, ONLY: grab_blip_coeffs, dump_matrix
    use mult_module, ONLY: return_matrix_value, matS
    ! Temp
    use S_matrix_module, ONLY: get_onsite_S
    use make_rad_tables, ONLY: gen_rad_tables, gen_nlpf_supp_tbls, get_support_pao_rep
    use angular_coeff_routines, ONLY: make_ang_coeffs, set_fact, set_prefac, set_prefac_real
    use read_support_spec, ONLY: read_support
    use functions_on_grid, ONLY: supportfns
    use support_spec_format, ONLY: supports_on_atom, coefficient_array, coeff_array_size, read_option

    implicit none

    ! Passed variables
    real(double) :: mu

    character(len=40) :: restart_file

    logical :: read_phi, vary_mu, start

    ! Local variables

    integer :: isf, np, ni, iprim, n_blip, n_run
    real(double) :: mu_copy
    real(double) :: factor
    logical, external :: leqi

    ! Used by pseudopotentials as well as PAOs
    if(flag_basis_set==blips) then
       if(inode==ionode) write(io_lun,fmt='(10x,"Using blips as basis set for support functions")')
       call set_blip_index(inode, ionode)
       call my_barrier
       if((inode == ionode) .AND. (iprint_init > 1)) write(io_lun,*) 'initial_phis:&
            & completed set_blip_index()'

       !if((inode == ionode).and.(iprint_init >= 0)) then
       !   write(unit=io_lun,fmt='(/" initial_phis: n_species:",i3)') n_species
       !   write(unit=io_lun,fmt='(/" initial_phis: r_h:",f12.6)') r_h
       !   write(unit=io_lun,fmt='(/" initial_phis: support_grid_spacing:"&
       !        &,f12.6)') support_grid_spacing
       !end if
       if(.NOT.read_option) then
          if(leqi(init_blip_flag,'gauss')) then
             call gauss2blip
          else if(leqi(init_blip_flag,'pao')) then
             call make_blips_from_paos(inode,ionode,n_species)
          else
             call cq_abort('initial_phis: init_blip_flag no good')
          end if
       end if
       call my_barrier
       if((inode == ionode).AND.(iprint_init > 0)) then
          write(unit=io_lun,fmt='(10x,"initial_phis: initial blip coeffs created")')
       end if

       ! Length scale Preconditioning.
       call make_pre(inode, ionode)
       ! Restart files
       if (.not.vary_mu) mu_copy = mu
       !     if (.not.start ) call reload(inode, ionode, &
       !          mu, expected_reduction, n_run, restart_file)
       !     if (start.and.(.not.start_blips)) call load_blip(inode, ionode, restart_file)
       ! Tweak DRB 2007/03/34 Remove need for start
       !if (start.and.(.not.start_blips)) then
       if (read_option) then
          if(inode==ionode.AND.iprint_init>0) write(io_lun,fmt='(10x,"Loading blips")')
          call grab_blip_coeffs(coefficient_array,coeff_array_size, inode)
       end if
       if(.not.vary_mu) mu = mu_copy
       ! Normalisation
       call blip_to_support_new(inode-1, supportfns)
       if((inode == ionode).AND.(iprint_init > 1)) then
          write(unit=io_lun,fmt='(10x,"initial_phis: completed blip_to_support()")')
       end if
       if (start .or. (.NOT.read_option)) then
          n_run = 0
          !     call normalise_support(support, inode, ionode,&
          !          NSF, SUPPORT_SIZE)
          !     call blip_to_support_new(inode-1, support, data_blip, &
          !          NSF, SUPPORT_SIZE, MAX_N_BLIPS)
          !     write(io_lun,*) 'S matrix for normalisation on Node= ',inode
          call get_matrix_elements_new(inode-1,rem_bucket(1),matS,supportfns,supportfns)
          iprim=0
          call start_timer(tmr_std_matrices)
          do np=1,bundle%groups_on_node
             if(bundle%nm_nodgroup(np) > 0) then
                do ni=1,bundle%nm_nodgroup(np)
                   iprim=iprim+1
                   do isf=1,mat(np,Srange)%ndimi(ni)
                      factor = return_matrix_value(matS,np,ni,iprim,0,isf,isf,1)
                      if(factor>very_small) then
                         factor=one/sqrt(factor)
                      else
                         factor = zero
                      end if
                      do n_blip=1,supports_on_atom(iprim)%supp_func(isf)%ncoeffs
                         supports_on_atom(iprim)%supp_func(isf)%coefficients(n_blip) = &
                              factor*supports_on_atom(iprim)%supp_func(isf)%coefficients(n_blip)
                      enddo ! n_blip
                   enddo ! isf
                enddo ! ni
             endif ! if the partition has atoms
          enddo ! np
          call stop_timer(tmr_std_matrices)
          call my_barrier()
          if(inode==ionode.AND.iprint_init>1) &
               write(io_lun,fmt='(10x,"Completed normalise_support")')
          call blip_to_support_new(inode-1, supportfns)
          call get_matrix_elements_new(inode-1,rem_bucket(1),matS,supportfns,supportfns)
          !call dump_matrix("NS",matS,inode)
       else
          if(inode==ionode.AND.iprint_init>1) &
               write(io_lun,fmt='(10x,"Skipped normalise_support")')
       end if
    else if(flag_basis_set==PAOs) then
       call gen_rad_tables(inode,ionode)
       call gen_nlpf_supp_tbls(inode,ionode)
       call make_ang_coeffs
       if(inode==ionode) write(io_lun,fmt='(10x,"Using PAOs as basis set for support functions")')
       !call make_pre_paos
       if((inode == ionode).and.(iprint_init >0)) then
          write(unit=io_lun,fmt='(10x,"initial_phis: n_species:",i3)') n_species
          write(unit=io_lun,fmt='(10x,"initial_phis: r_h:",f12.6)') r_h
       end if
       ! We don't need a PAO equivalent of blip_to_support here: this is done by get_S_matrix
    end if
    return
  end subroutine initial_phis
!!***

!!****f* initialisation/initial_H *
!!
!!  NAME 
!!   initial_H
!!  USAGE
!! 
!!  PURPOSE
!!   Makes an initial, self-consistent Hamiltonian (and potential)
!!  INPUTS
!! 
!! 
!!  USES
!!   datatypes, DMMin, ewald_module, GenComms, global_module, logicals, 
!!   matrix_data, mult_module, numbers, SelfCon, S_matrix_module
!!  AUTHOR
!!   D.R.Bowler
!!  CREATION DATE
!!   14/05/99
!!  MODIFICATION HISTORY
!!   18/05/2001 dave
!!    Stripped down call to new_SC_potl
!!   25/05/2001 dave
!!    Used S_matrix_module for get_S_matrix
!!    Shortened overall subroutine call
!!   08/06/2001 dave
!!    Used GenComms and added RCS Id and Log tags
!!   13/06/2001 dave
!!    Removed get_core_correction (a routine which does
!!    not need to be passed a pig)
!!   17/06/2002 dave
!!    Improved headers slightly and changed call to main_matrix_multiply to remove unnecessary work
!!   15:38, 04/02/2003 drb 
!!    Added all sorts of calls for testing forces: left in for now, but commented out, so that we can
!!    see the kinds of things that need to be done
!!   14:33, 26/02/2003 drb 
!!    Added appropriate calls based on whether or not we're doing self-consistency
!!   15:55, 27/02/2003 drb & tm 
!!    Changed call to get_H_matrix to turn off charge generation
!!   08:34, 2003/03/12 dave
!!    Added call to get_energy after FindMinDM
!!   12:01, 30/09/2003 drb 
!!    Added force-testing call, tidied
!!   13:12, 22/10/2003 mjg & drb 
!!    Added old/new ewald call
!!   09:13, 11/05/2005 dave 
!!    Stopped FindMinDM if restart_L flag set
!!   2005/07/11 10:24 dave
!!    Removed redeclaration of restart flags
!!   10:09, 13/02/2006 drb 
!!    Removed all explicit references to data_ variables and rewrote in terms of new 
!!    matrix routines
!!  SOURCE
!!
  subroutine initial_H( start, start_L, find_chdens, fixed_potential, vary_mu, number_of_bands, mu, total_energy)

    use datatypes
    use numbers
    use logicals
    use mult_module, ONLY: LNV_matrix_multiply, matL, matphi
    use SelfCon, ONLY: new_SC_potl
    use global_module, ONLY: iprint_init, flag_self_consistent, flag_basis_set, blips, PAOs, flag_vary_basis, &
         restart_L, restart_rho, flag_test_forces
    use ewald_module, ONLY: ewald, mikes_ewald, flag_old_ewald
    use S_matrix_module, ONLY: get_S_matrix
    use GenComms, ONLY: my_barrier, end_comms, inode, ionode
    use DMMin, ONLY: correct_electron_number, FindMinDM
    use H_matrix_module, ONLY: get_H_matrix
    use energy, ONLY: get_energy
    use test_force_module, ONLY: test_forces
    use io_module, ONLY: grab_matrix, grab_charge
    use DiagModule, ONLY: diagon
    use density_module, ONLY: get_electronic_density, density
    use functions_on_grid, ONLY: supportfns, H_on_supportfns
    use dimens, ONLY: n_my_grid_points
    use maxima_module, ONLY: maxngrid
    use minimise, ONLY: SC_tolerance, L_tolerance, n_L_iterations, expected_reduction

    implicit none

    ! Passed variables
    logical :: vary_mu, find_chdens, fixed_potential
    logical :: start, start_L

    real(double) :: number_of_bands, mu
    real(double) :: total_energy

    ! Local
    logical :: reset_L, charge, store
    integer :: force_to_test, stat
    real(double) :: electrons, bandE
    ! Dummy vars for MMM

    total_energy = zero
    ! If we're vary PAOs, allocate memory
    ! (1) Get S matrix
    call get_S_matrix(inode, ionode)
    if(inode==ionode.AND.iprint_init>1) write(io_lun,*) 'Got S'
    call my_barrier

    ! (2) Make an inital estimate for the density matrix, L, which is an
    ! approximation to L = S^-1. Then use correct_electron_number()
    ! to modify L so that the electron number is correct. (not done now)
    !start_L = .false.
    if (.NOT.diagon.AND.find_chdens.AND.(start .or. start_L)) then
       call initial_L( )
       call my_barrier()
       if (inode.eq.ionode.AND.iprint_init>1) write(io_lun,*) 'Got L matrix'
       if(vary_mu) then
            ! This cannot be timed within the routine
            call start_timer(tmr_std_densitymat)
            call correct_electron_number( iprint_init, number_of_bands, inode, ionode)
            call stop_timer(tmr_std_densitymat)
       end if
    end if
    if(restart_L) call grab_matrix("L",matL,inode)

    ! (3) get K matrix
    if(.NOT.diagon.AND.(find_chdens.OR.restart_L)) then
       call LNV_matrix_multiply(electrons, total_energy, &
            doK, dontM1, dontM2, dontM3, dontM4, dophi, dontE,0,0,0,matphi)
       if(inode==ionode.AND.iprint_init>1) write(io_lun,*) 'Got elect: ',electrons
    end if

    ! (4) get the core correction to the pseudopotential energy
    ! (note that this routine does not need to be passed a pig)

    ! (5) Find the Ewald energy for the initial set of atoms
    if(inode==ionode.AND.iprint_init>1) write(io_lun,*) 'Calling Ewald'
    if(flag_old_ewald) then
       call ewald
    else
       call mikes_ewald
    end if
    ! +++
    call my_barrier

    if(inode==ionode.AND.iprint_init>2) write(io_lun,*) 'Find_chdens is ',find_chdens
    ! (6) Make a self-consistent H matrix and potential
    if(find_chdens) then
       call get_electronic_density(density, electrons, supportfns, H_on_supportfns, inode, ionode, maxngrid)
       if(inode==ionode.AND.iprint_init>1) write(io_lun,*) 'In initial_H, electrons: ',electrons
    else if(restart_rho) then
       call grab_charge(density,n_my_grid_points,inode)
    endif
    reset_L = .true.
    if(flag_self_consistent) then ! Vary only DM and charge density
       !OLD call new_SC_potl( .true., SC_tolerance, reset_L, fixed_potential, vary_mu, n_L_iterations, &
       !OLD      number_of_bands, L_tolerance, mu, total_energy)
      if(restart_L) then
       reset_L=.false.
       call new_SC_potl( .true., SC_tolerance, reset_L, fixed_potential, vary_mu, n_L_iterations, &
            number_of_bands, L_tolerance, mu, total_energy)
      else
       reset_L=.true.
       call get_H_matrix(.true., fixed_potential, electrons, density, maxngrid)
       call FindMinDM(n_L_iterations, number_of_bands, vary_mu, &
            L_tolerance, mu, inode, ionode, reset_L, .false.)
       reset_L=.false.
       call new_SC_potl( .true., SC_tolerance, reset_L, fixed_potential, vary_mu, n_L_iterations, &
            number_of_bands, L_tolerance, mu, total_energy)
      endif
    else ! Ab initio TB: vary only DM
       call get_H_matrix(.true., fixed_potential, electrons, density, maxngrid)
       !OLD if(.NOT.restart_L) call FindMinDM(n_L_iterations, number_of_bands, vary_mu, &
       !OLD      L_tolerance, mu, inode, ionode, reset_L, .false.)
       if(.NOT.restart_L) then
        call FindMinDM(n_L_iterations, number_of_bands, vary_mu, L_tolerance, mu, inode, ionode, reset_L, .false.)
       else
        call FindMinDM(n_L_iterations, number_of_bands, vary_mu, L_tolerance, mu, inode, ionode, .false., .false.)
       endif
       call get_energy(total_energy)
    end if
    ! Do we want to just test the forces ?
    if(flag_test_forces) then
       call test_forces(fixed_potential, vary_mu, n_L_iterations, &
            number_of_bands, L_tolerance, L_tolerance, mu, &
            total_energy, expected_reduction)
       call end_comms
       stop
    end if
    return
5   format(2x,'Energy as 2Tr[K.H]: ',f18.11,' eV')
6   format(2x,'2Tr[S.G]: ',f18.11,' eV')
  end subroutine initial_H
!!***

! ------------------------------------------------------------------------------
! setgrid
! ------------------------------------------------------------------------------

!!****f* initialisation/setgrid *
!!
!!  NAME 
!!   setgrid_new
!!  USAGE
!! 
!!  PURPOSE
!!   Overall control of everything grid-related
!!  INPUTS
!! 
!! 
!!  USES
!! 
!!  AUTHOR
!!   T. Miyazaki
!!  CREATION DATE
!!   Sometime 2000-2001
!!  MODIFICATION HISTORY
!!   09:33, 11/05/2005 dave 
!!    Added ROBODoc header, indented code, added 1.1 factor to rcut_max
!!  SOURCE
!!
  subroutine setgrid(myid,r_core_squared,r_h)

    !Modules and Dummy Arguments
    use datatypes
    use numbers,          ONLY: very_small
    use global_module,    ONLY: x_atom_cell,y_atom_cell,z_atom_cell, ni_in_cell, iprint_index
    use block_module,     ONLY: n_pts_in_block
    use maxima_module,    ONLY: maxblocks
    use group_module,     ONLY: blocks, parts
    use construct_module, ONLY: init_primary, init_cover
    use primary_module,   ONLY: domain, bundle, make_prim
    use cover_module,     ONLY: DCS_parts, BCS_blocks, make_cs, make_iprim, send_ncover, BCS_parts
    use set_blipgrid_module, ONLY: set_blipgrid
    use set_bucket_module,   ONLY: set_bucket
    use GenComms, ONLY: my_barrier
    use dimens, ONLY: RadiusSupport
    use pseudopotential_common, ONLY: core_radius
    use blip, ONLY: Extent

    implicit none
    integer,intent(in)      :: myid
    real(double),intent(in) :: r_core_squared, r_h

    !Local variables
    ! Temporary
    logical, external :: leqi
    real(double) :: rcut_max,r_core

    !-- Start of the subroutine (set_grid_new)
    if(myid == 0.AND.iprint_index>1) write(io_lun,*) 'setgrid_new starts'
    if(iprint_index > 4) write(io_lun,*) ' setgrid_new starts for myid= ',myid

    !Sets up domain
    call init_primary(domain, n_pts_in_block*maxblocks, maxblocks, .false.)
    if(iprint_index > 4) write(io_lun,*) 'init_primary end for myid = ',myid,' par = ',n_pts_in_block, maxblocks
    ! call my_barrier()  !TMP
    call make_prim(blocks, domain, myid)
    if(iprint_index > 4) write(io_lun,*) 'make_prim end for myid = ',myid
    !Sets up DCS_parts& BCS_blocks
    r_core=sqrt(r_core_squared)
    ! No longer necessary as this is done in dimens_module
    !if(leqi(runtype,'static')) then
    rcut_max=max(r_core,r_h)+very_small
    !else
    !   rcut_max=1.1_double*(max(r_core,r_h)+very_small)
    !endif
    if(iprint_index > 4) write(io_lun,*) ' rcut_max for DCS_parts and BCS_blocks = ',rcut_max, r_core, r_h

    call make_cs(myid,rcut_max, DCS_parts , parts , domain, ni_in_cell, x_atom_cell, y_atom_cell, z_atom_cell)
    if(iprint_index > 4) write(io_lun,*) 'Node ',myid+1,' Done make_DCSparts'
    call make_cs(myid,rcut_max, BCS_blocks, blocks, bundle)
    if(iprint_index > 4) write(io_lun,*) 'Node ',myid+1,' Done make_BCSblocks'

    !call make_iprim(DCS_parts,bundle,myid) !primary number for members
    !  write(io_lun,*) 'Node ',myid+1,' Done make_iprim'
    call my_barrier

    call send_ncover(DCS_parts,myid+1)
    if(iprint_index > 4) write(io_lun,*) 'Node ',myid+1,' Done send_ncover for DCS_parts'
    call my_barrier
    call send_ncover(BCS_blocks,myid+1)
    if(iprint_index > 4) write(io_lun,*) 'Node ',myid+1,' Done send_ncover for BCS_blocks'

    if(iprint_index > 4) call check_setgrid

    if(iprint_index > 4) write(io_lun,*) ' DCS & BCS has been prepared for myid = ',myid
    !Makes variables used in Blip-Grid transforms
    ! See (naba_blk_module.f90), (set_blipgrid_module.f90), (make_table.f90)
    call set_blipgrid(myid,RadiusSupport,core_radius,Extent)
    if(iprint_index > 4) write(io_lun,*) 'Node ',myid+1,' Done set_blipgrid'

    !Makes variables used in calculation (integration) of matrix elements
    ! See (bucket_module.f90) and (set_bucket_module.f90)
    call set_bucket(myid)
    if(iprint_index > 4) write(io_lun,*) 'Node ',myid+1,' Done set_bucket'

    return
  end subroutine setgrid
!!***
  
  subroutine check_setgrid

    use global_module,    ONLY: numprocs,rcellx,rcelly,rcellz, iprint_index
    use GenComms, ONLY: myid, my_barrier
    use group_module,     ONLY: blocks, parts
    use primary_module,   ONLY: domain, bundle, make_prim
    use cover_module,     ONLY: DCS_parts, BCS_blocks, make_cs, make_iprim, send_ncover, BCS_parts
    
    implicit none

    integer :: nnd,nnd2
    real(double) :: xx,yy,zz,dcellx,dcelly,dcellz
    integer :: nnx,nny,nnz
    integer :: no_of_naba_atom,ip
    integer :: ierror=0

    !FOR DEBUGGING
    if(iprint_index > 4) then
       call my_barrier()
       !-- CHECK -- bundle
       dcellx=rcellx/parts%ngcellx
       dcelly=rcelly/parts%ngcelly
       dcellz=rcellz/parts%ngcellz
       do nnd=1,numprocs
          if(myid == nnd-1) then
             write(io_lun,*)
             write(io_lun,*) ' Node ',nnd,' CHECK bundle '
             write(io_lun,*) ' n_prim, groups_on_node = ', bundle%n_prim,bundle%groups_on_node
             write(io_lun,101) bundle%nx_origin,bundle%ny_origin,bundle%nz_origin
             write(io_lun,102) bundle%nw_primx ,bundle%nw_primy ,bundle%nw_primz
             write(io_lun,103) bundle%nleftx   ,bundle%nlefty   ,bundle%nleftz  
             nnx=bundle%nx_origin-bundle%nleftx
             nny=bundle%ny_origin-bundle%nlefty
             nnz=bundle%nz_origin-bundle%nleftz
             xx=(nnx-1)*dcellx
             yy=(nny-1)*dcelly
             zz=(nnz-1)*dcellz
             write(io_lun,104) xx,yy,zz
             nnx=nnx+bundle%nw_primx-1
             nny=nny+bundle%nw_primy-1
             nnz=nnz+bundle%nw_primz-1
             xx=nnx*dcellx
             yy=nny*dcelly
             zz=nnz*dcellz
             write(io_lun,105) xx,yy,zz
101          format(3x,' origin    ',3i5)
102          format(3x,' width     ',3i5)
103          format(3x,' left_span ',3i5)
104          format(3x,' Left  Down Bottom',3f15.6)
105          format(3x,' Right  Up   TOP  ',3f15.6)
          endif
          call my_barrier()
       enddo

       !-- CHECK -- domain
       dcellx=rcellx/blocks%ngcellx
       dcelly=rcelly/blocks%ngcelly
       dcellz=rcellz/blocks%ngcellz
       do nnd=1,numprocs
          if(myid == nnd-1) then
             write(io_lun,*)
             write(io_lun,*) ' Node ',nnd,' CHECK domain '
             write(io_lun,*) ' n_prim, groups_on_node = ', domain%n_prim,domain%groups_on_node
             write(io_lun,101) domain%nx_origin,domain%ny_origin,domain%nz_origin
             write(io_lun,102) domain%nw_primx ,domain%nw_primy ,domain%nw_primz
             write(io_lun,103) domain%nleftx   ,domain%nlefty   ,domain%nleftz 
             nnx=domain%nx_origin-domain%nleftx
             nny=domain%ny_origin-domain%nlefty
             nnz=domain%nz_origin-domain%nleftz
             xx=(nnx-1)*dcellx
             yy=(nny-1)*dcelly
             zz=(nnz-1)*dcellz
             write(io_lun,104) xx,yy,zz
             nnx=nnx+domain%nw_primx-1
             nny=nny+domain%nw_primy-1
             nnz=nnz+domain%nw_primz-1
             xx=nnx*dcellx
             yy=nny*dcelly
             zz=nnz*dcellz
             write(io_lun,105) xx,yy,zz
             !101 format(3x,' origin    ',3i5)
             !102 format(3x,' width     ',3i5)
             !103 format(3x,' left_span ',3i5)
             !104 format(3x,' Left  Down Bottom',3f15.6)
             !105 format(3x,' Right  Up   TOP  ',3f15.6)
             !write(io_lun,*) ' @@ mx_nbonn for node ',nnd,' >= ',domain%groups_on_node
             !if(domain%groups_on_node > mx_nbonn) ierror=ierror+1
          endif
          call my_barrier()
       enddo

       !-- CHECK -- BCS_parts
       dcellx=rcellx/parts%ngcellx
       dcelly=rcelly/parts%ngcelly
       dcellz=rcellz/parts%ngcellz
       do nnd2=1,numprocs
          if(myid ==nnd2-1 ) then
             write(io_lun,*) 
             write(io_lun,*) ' Node ', nnd2, ' CHECK BCS_parts'
             write(io_lun,101) BCS_parts%nx_origin, BCS_parts%ny_origin, BCS_parts%nz_origin
             write(io_lun,102) BCS_parts%ncoverx  , BCS_parts%ncovery  , BCS_parts%ncoverz
             write(io_lun,103) BCS_parts%nspanlx  , BCS_parts%nspanly  , BCS_parts%nspanlz
             nnx=BCS_parts%nx_origin-BCS_parts%nspanlx
             nny=BCS_parts%ny_origin-BCS_parts%nspanly
             nnz=BCS_parts%nz_origin-BCS_parts%nspanlz
             xx=(nnx-1)*dcellx
             yy=(nny-1)*dcelly
             zz=(nnz-1)*dcellz
             write(io_lun,104) xx,yy,zz
             nnx=nnx+BCS_parts%ncoverx-1
             nny=nny+BCS_parts%ncovery-1
             nnz=nnz+BCS_parts%ncoverz-1
             xx=nnx*dcellx
             yy=nny*dcelly
             zz=nnz*dcellz
             write(io_lun,105) xx,yy,zz
             do nnd=1,numprocs
                write(io_lun,*) ' for Node = ',nnd,' BCSparts_ncover_remote ',&
                     BCS_parts%ncover_rem(1+3*(nnd-1)),&
                     BCS_parts%ncover_rem(2+3*(nnd-1)),&
                     BCS_parts%ncover_rem(3+3*(nnd-1))
             enddo
          endif
          call my_barrier()
       enddo
       !-- CHECK -- DCS_parts
       do nnd2=1,numprocs
          if(myid ==nnd2-1 ) then
             write(io_lun,*)
             write(io_lun,*) ' Node ', nnd2, ' CHECK DCS_parts'
             write(io_lun,101) DCS_parts%nx_origin, DCS_parts%ny_origin, DCS_parts%nz_origin
             write(io_lun,102) DCS_parts%ncoverx  , DCS_parts%ncovery  , DCS_parts%ncoverz
             write(io_lun,103) DCS_parts%nspanlx  , DCS_parts%nspanly  , DCS_parts%nspanlz
             nnx=DCS_parts%nx_origin-DCS_parts%nspanlx
             nny=DCS_parts%ny_origin-DCS_parts%nspanly
             nnz=DCS_parts%nz_origin-DCS_parts%nspanlz
             xx=(nnx-1)*dcellx
             yy=(nny-1)*dcelly
             zz=(nnz-1)*dcellz
             write(io_lun,104) xx,yy,zz
             nnx=nnx+DCS_parts%ncoverx-1
             nny=nny+DCS_parts%ncovery-1
             nnz=nnz+DCS_parts%ncoverz-1
             xx=nnx*dcellx
             yy=nny*dcelly
             zz=nnz*dcellz
             write(io_lun,105) xx,yy,zz
             do nnd=1,numprocs
                write(io_lun,*) ' for Node = ',nnd,' BCSparts_ncover_remote ',&
                     DCS_parts%ncover_rem(1+3*(nnd-1)),&
                     DCS_parts%ncover_rem(2+3*(nnd-1)),&
                     DCS_parts%ncover_rem(3+3*(nnd-1))
             enddo
             !write(io_lun,*) ' @@ mx_pcover_DCS for node ',nnd2,' >= ',DCS_parts%ng_cover
             !if(DCS_parts%ng_cover > mx_pcover_DCS) ierror=ierror+2
             no_of_naba_atom=0
             do ip=1,DCS_parts%ng_cover
                no_of_naba_atom=no_of_naba_atom+DCS_parts%n_ing_cover(ip)
             enddo
             !write(io_lun,*) ' @@ mx_icover_DCS for node ',nnd2,' >= ',&
             !     DCS_parts%icover_ibeg(DCS_parts%ng_cover)+DCS_parts%n_ing_cover(DCS_parts%ng_cover)-1, &
             !     no_of_naba_atom
             !if(mx_icover_DCS < no_of_naba_atom) ierror=ierror+4
          endif
          call my_barrier()
       enddo
       !-- CHECK -- BCS_blocks
       dcellx=rcellx/blocks%ngcellx
       dcelly=rcelly/blocks%ngcelly
       dcellz=rcellz/blocks%ngcellz
       do nnd2=1,numprocs
          if(myid ==nnd2-1 ) then
             write(io_lun,*)
             write(io_lun,*) ' Node ', nnd2, ' CHECK BCS_blocks'
             write(io_lun,101) BCS_blocks%nx_origin, BCS_blocks%ny_origin, BCS_blocks%nz_origin
             write(io_lun,102) BCS_blocks%ncoverx  , BCS_blocks%ncovery  , BCS_blocks%ncoverz
             write(io_lun,103) BCS_blocks%nspanlx  , BCS_blocks%nspanly  , BCS_blocks%nspanlz
             nnx=BCS_blocks%nx_origin-BCS_blocks%nspanlx
             nny=BCS_blocks%ny_origin-BCS_blocks%nspanly
             nnz=BCS_blocks%nz_origin-BCS_blocks%nspanlz
             xx=(nnx-1)*dcellx
             yy=(nny-1)*dcelly
             zz=(nnz-1)*dcellz
             write(io_lun,104) xx,yy,zz
             nnx=nnx+BCS_blocks%ncoverx-1
             nny=nny+BCS_blocks%ncovery-1
             nnz=nnz+BCS_blocks%ncoverz-1
             xx=nnx*dcellx
             yy=nny*dcelly
             zz=nnz*dcellz
             write(io_lun,105) xx,yy,zz
             do nnd=1,numprocs
                write(io_lun,*) ' for Node = ',nnd,' BCSparts_ncover_remote ',&
                     BCS_blocks%ncover_rem(1+3*(nnd-1)),&
                     BCS_blocks%ncover_rem(2+3*(nnd-1)),&
                     BCS_blocks%ncover_rem(3+3*(nnd-1))
             enddo
             write(io_lun,*) ' @@ mx_bcover for node ',nnd2,' >= ',BCS_blocks%ng_cover
             !if(BCS_blocks%ng_cover > mx_bcover) ierror=ierror+8
          endif
          call my_barrier()
       enddo
    end if
    !END OF DEBUGGING

  end subroutine check_setgrid

!!****f* initialisation/initial_L *
!!
!!  NAME 
!!   initial_L
!!  USAGE
!! 
!!  PURPOSE
!!   Finds initial L (set equal to 1/2 S^-1)
!!  INPUTS
!! 
!! 
!!  USES
!! 
!!  AUTHOR
!!   D.R.Bowler/C.M.Goringe
!!  CREATION DATE
!!   07/03/95
!!  MODIFICATION HISTORY
!!   04/05/01 dave
!!    Takes S^-1 from Hotelling's method
!!   21/06/2001 dave
!!    Added ROBODoc header and indented
!!   12:20, 2004/06/09 dave
!!    Fixed bug: Srange not Trange in final option
!!   10:09, 13/02/2006 drb 
!!    Removed all explicit references to data_ variables and rewrote in terms of new 
!!    matrix routines
!!   2006/11/14 07:58 dave
!!    Included in initialisation
!!  SOURCE
!!
  subroutine initial_L( )

    use datatypes
    use numbers, ONLY: half, zero
    use mult_module, ONLY: matL, matT, matrix_sum

    implicit none

    ! Local variables

    call matrix_sum(zero,matL,half,matT)
    return
  end subroutine initial_L
!!***
      



end module initialisation
