!    PUReIBM-PS2D-FD1D is a three-dimensional psudeo-spectral particle-resolved
!    direct numerical simulation solver for detailed analysis of homogeneous
!    fixed and freely evolving fluid-particle suspensions. PUReIBM-PS2D-FD1D
!    is a continuum Navier-Stokes and scalar solvers based on Cartesian grid that utilizes
!    Immeresed Boundary method to represent particle surfuces. The details about the solvers
!    can be found in the below papers in SUBRAMANIAM's group. 
!    Copyright (C) 2015, Shankar Subramaniam, Rahul Garg, Sudheer Tenneti, Bo Sun, Mohammad Mehrabadi
!
!    This program is free software: you can redistribute it and/or modify
!    it under the terms of the GNU General Public License as published by
!    the Free Software Foundation, either version 3 of the License, or
!    (at your option) any later version.
!
!    This program is distributed in the hope that it will be useful,
!    but WITHOUT ANY WARRANTY; without even the implied warranty of
!    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!    GNU General Public License for more details.
!
!    You should have received a copy of the GNU General Public License
!    along with this program.  If not, see <http://www.gnu.org/licenses/>.
!
!    For acknowledgement, please refer to the following publications:
!     For hydrodynamic solver :
!     (1) TENNETI, S. and SUBRAMANIAM, S., 2014, Particle-resolved direct numerical
!         simulation for gas-solid flow model development. Annu. Rev. Fluid Mech.
!         46 (1) 199-230.
!     (2) M. Mehrabadi, S. Tenneti, R. Garg, and S. Subramaniam, 2015, Pseudo-turbulent 
!         gas-phase velocity fluctuations in homogeneous gas-solid flow: fixed particle
!         assemblies and freely evolving suspensions. J. Fluid Mech. 770 210-246.
!
!     For scalar solver :
!     (3) S. Tenneti, B. Sun, R. Garg, S. Subramaniam, 2013, Role of fluid heating in dense
!         gas-solid flow as revealed by particle-resolved direct numerical simulation.
!         International Journal of Heat and Mass Transfer 58 471-479.

MODULE nl_allphi
#include "../FLO/ibm.h"
  USE precision 
  USE constants 
  USE fftw_interface
  USE scalar_data 

  USE functions, ONLY : maxzero
#if !PARALLEL
  USE nlarrays, ONLY : uf1,uf2,uf3, phif1=>uf11, uf1phif=>uf12,&
       & uf2phif=>uf13,uf3phif=>uf23, ur1,ur2,ur3, phir1=>ur11,&
       & ur1phi=>ur12, ur2phi=>ur13, ur3phi=>ur23
#else
  USE nlarrays, ONLY : uf1,uf2,uf3, phif1=>uf11, uf1phif=>uf12,&
       & uf2phif=>uf13,uf3phif=>uf23, ur1,ur2,ur3, phir1=>ur11,&
       & ur1phi=>ur12, ur2phi=>ur13, ur3phi=>ur23, uatminus1, uatnxp2
#endif  
  IMPLICIT NONE 

  PRIVATE 
  INTEGER :: mx2
  PUBLIC :: form_nlphi, compute_phim_heat_ratio 
CONTAINS
  SUBROUTINE form_nlphi

    USE bcsetarrays, fdderiv=>fr  

    Use nlmainarrays, Only : ubcp, phirbcp=>nlbcp
    IMPLICIT NONE 
    INTEGER :: i,j,k, im1, ip1, isp,im2,ip2,umean_flag,count_neg 
    REAL(prcn) :: Dplus_vj, Dminus_vj, max_speed,phifmeanloc(nspmx) &
         &,phismeanloc(nspmx), phimodmeanloc(nspmx), slope_factor, phi_ri
    REAL(prcn) :: per_facp1(nspmx), per_facm1(nspmx)
    !#if !PARALLEL
    !    REAL(PRCN) :: uplus(mx1), uminus(mx1), U_plus(mx1),&
    !         & U_minus(mx1), slope_u(mx1),slope_phi(mx1)
    !#else
    REAL(PRCN), ALLOCATABLE, DIMENSION(:) :: uplus, uminus, U_plus,&
         & U_minus, slope_u, slope_phi
    !#endif

#if 0
    if(irestart.eq.0) then 
       if(iglobstep.le.100) then
          slope_factor = nl_slope_factor*real(iglobstep-1,prcn)/100.d0
       ELSE
          slope_factor = nl_slope_factor
          !discr_scheme = "center"
       end if
    ELSE
       slope_factor = nl_slope_factor
    end if
#endif
    slope_factor = one
    phi_ri = one

    if(I_AM_NODE_ZERO)WRITE(*,'(A,2x,g17.8)')'SLOPE FACTOR IN NLPHI = ', slope_factor 

    mx2 = mx+1
    do isp = 1, nspmx
#if !PARALLEL
       do i = 1, nx+1 !mx1
#else
       do i = 0, nx+1
#endif
          DO k = 1,mz
             DO j = 1, my2
                phif1(j,k) = phif(i,j,k,isp)
             END DO
          END DO
          
          CALL ff2cr(phif1,phirbcp(i,:,:,isp))
          
          do k = 1, mz
             do j = 1, my 
                if(discr_scheme.eq.'center')then
                   ur1phi(j,k)  = ubcp(i,j,k,1)*phirbcp(i,j,k,isp)
                endif
                ur2phi(j,k)  = ubcp(i,j,k,2)*phirbcp(i,j,k,isp)
                ur3phi(j,k)  = ubcp(i,j,k,3)*phirbcp(i,j,k,isp)
             end do
          end do
          ! Please note that phi in real space is stored in nlbc(0:nx+1,:,:,:)
          ! in this function. Later after finding the fluxes etc, in
          ! the same function, the real space phi is replaced into
          ! ubcp(0:nx+1,:,:,:). Please note the buffers into which I
          ! am sending the data in the two lines below this comment.
          ! Phirbc(2,:,:,:) is sent to ubcp(nx+2,:,:,:). These two
          ! extra buffers are needed for RPR operations. Since we
          ! will not be using ubcp(-1,j,k,:) and ubcp(nx+2,j,k,:) in this function,
          ! filling up those locations is safe. Also note a VERY
          ! important fact. phirbcp() is of size nx+2, whereas ubcp()
          ! is of size nx+4. So, while sending the non contiguous data blocks, these
          ! two arrays have different strides. Hence the use of
          ! VECSENDRECV2 which sends data between different
          ! stridetypes. VECSENDRECV sends data between similar stride
          ! types. See ../FLO/ibm.h for both these definitions.
          
          if(i.eq.2)then
             VECSENDRECV2(phirbcp(i,1,1,isp),1,twodrslice,fromproc,1,ubcp(nx+2,1,1,isp),1,urslice,toproc,1,decomp_group,status)
          else if(i.eq.nx-1)then 
             VECSENDRECV2(phirbcp(i,1,1,isp),1,twodrslice,toproc,0,ubcp(-1,1,1,isp),1,urslice,fromproc,0,decomp_group,status)
          end if
          call ff2rc(ur2phi, uf2phif)
          call ff2rc(ur3phi, uf3phif)
          
          do k  = 1, mz 
             do j = 1, my
#if PARALLEL                
                if((j.le.my2).and.(i.gt.0).and.(i.le.nx)) then 
#else
                   if((j.le.my2).and.(i.gt.0).and.(i.le.nx+1)) then 
#endif
                      nlphif(i,j,k,isp) = wy(j)*uf2phif(j,k) + wz(k)*uf3phif(j,k)
                   end if
                   if(discr_scheme.eq."center")then
                      fdderiv(i,j,k,isp) = ur1phi(j,k)
                   else
                      fdderiv(i,j,k,isp)= zero
                   end if
                end do
             end do
          end do !i=1, mx1
       end do !isp

       CALL compute_phim_heat_ratio(.TRUE.)!(ubcp,phirbcp)
!!$
!!$    do isp = 1, nspmx
!!$       phirbcp(mx,:,:,isp) = phirbcp(1, :,:,isp)/heat_ratio(isp)
!!$    end do

#if PARALLEL
       do isp=1,nspmx
          do k = 1, mz
             do j = 1,my
                if(xstart.eq.1) ubcp(-1,j,k,isp) = heat_ratio(isp)*ubcp(-1,j,k,isp)
                if(I_AM_LAST_PROC)ubcp(nx+2,j,k,isp) = ubcp(nx+2,j,k,isp)/heat_ratio(isp)
             end do
          end do
       end do
#endif

#if !PARALLEL
       if(discr_scheme.eq."center") then
          do isp = 1, nspmx
             fdderiv(0,:,:,isp) = fdderiv(mx1,:,:,isp)*heat_ratio(isp)
             !fdderiv(mx,:,:,isp) = fdderiv(1,:,:,isp)/heat_ratio(isp)
          end do
       else
          do isp = 1, nspmx
             fdderiv(0,:,:,isp) = zero
             !fdderiv(mx,:,:,isp) = zero
          end do
       end if
#endif
       if(discr_scheme.eq."upwind")then
!!$                         xi-1/2    xi+1/2          
!!$                     ......|..........|.......
!!$                     |          |            |
!!$                    xi-1        xi          xi+1   
          
!!$                   We need to compute (del f/del x)|i, where f = uT (T is the scalar)

!!$                      (del f/del x)|i = (f(i+1/2) - f(i-1/2))/dx
!!$ These are like finite volume cells centered around {xi}.
!!$ We cannot compute f(i+1/2) and f(i-1/2) directly since the polynomials are
!!$ discontinuous at these interfaces. 
!!$   For a second order accurate scheme, one must consider piecewise
!!$   linear polynomials.
          !#if PARALLEL
          if(.not.ALLOCATED(slope_u))then
             !          BARRIER(decomp_group)
             ALLOCATE(uplus(0:nx+1), uminus(0:nx+1), U_plus(0:nx+1),&
                  & U_minus(0:nx+1), slope_u(0:nx+1), slope_phi(0:nx+1))
          end if
             !#endif

          do isp = 1, nspmx
             do k = 1, mz
                do j = 1, my
#if PARALLEL
                   
                   slope_phi(0) = (phirbcp(1,j,k,isp)-ubcp(-1,j,k,isp))/(two*dx) 
                   U_minus(0) = phirbcp(0,j,k,isp) + slope_phi(0)*dx/two
                   
                   slope_phi(nx+1) = (ubcp(nx+2,j,k,isp)-phirbcp(nx,j,k,isp))/(two*dx) 
                   U_plus(nx) = phirbcp(nx+1,j,k,isp) - slope_phi(nx+1)*(dx/two)  ! Uplus(i-1/2)
                   
                   IF(isp.eq.1)then
                      slope_u(0) = (ubcp(1,j,k,1)-uatminus1(j,k))/(two*dx)
                      uminus(0) = ubcp(0,j,k,1) + slope_u(0)*(dx/two)
                      
                      slope_u(nx+1) = (uatnxp2(j,k)-ubcp(nx,j,k,1))/(two*dx)
                      
                      uplus(nx) = ubcp(nx+1,j,k,1) - slope_u(nx+1)*(dx/two)
                      
                   END IF
#else
                   slope_phi(0) = (phirbcp(1,j,k,isp)-phirbcp(mx1-1,j,k&
                        &,isp)*heat_ratio(isp))/(two*dx) 
                   
                   U_minus(0) =  phirbcp(mx1,j,k,isp)*heat_ratio(isp) +&
                        & slope_phi(0)*(dx/two) ! Uminus(i+1/2)
                   
                   
                   slope_phi(mx) = (phirbcp(2,j,k,isp)/heat_ratio(isp)&
                        &-phirbcp(mx1,j,k,isp))/(two*dx) 
                   
                   
                   U_plus(mx1) = phirbcp(1,j,k,isp)/heat_ratio(isp) -&
                        & slope_phi(mx)*(dx/two)  ! Uplus(i-1/2)
                   
                   
                   IF(isp.eq.1)then
                      slope_u(0) = (ubcp(1,j,k,1)-ubcp(mx1-1,j,k,1))&
                           &/(two*dx)
                      uminus(0) =  ubcp(mx1,j,k,1) + slope_u(0)*(dx/two) !
                      ! uminus(xi+1/2
                      slope_u(mx) = (ubcp(2,j,k,1)-ubcp(mx1,j,k,1))/(two&
                           &*dx)
                      uplus(mx1) = ubcp(1,j,k,1) - slope_u(mx)*(dx/two) !
                      ! uplus(xi-1/2)
                      
                   END IF
#endif
                   do i = 1,nx !mx1
                      im1 = i-1
                      ip1 = i+1
                      per_facm1(isp) = one
                      per_facp1(isp) = one
#if !PARALLEL
                      if(im1.lt.1) then
                         im1 = mxf+im1-1
                         per_facm1(isp) = heat_ratio(isp)
                      end if
                      if(ip1.gt.mxf)then
                         ip1 = ip1-(mxf-1)
                         per_facp1(isp) = one/heat_ratio(isp)
                      end if
#endif
!!$ We have information at the grid locations {xi}. Consider piecewise linear polynomials in the intervals 
!!$   [xi-1/2,xi+1/2].
                      
!!$ Form of the piecewise polynomial:
!!$   P[U](i) = U(i) + Sj*(x-x(i)); Sj is the slope of the  piecewise polynomial. Now how to choose the slope of the polynomial? 
!!$ First Order: Sj = 0
                      
!!$ Second Order: 
                      slope_phi(i) = (per_facp1(isp)*phirbcp(ip1,j,k&
                           &,isp)-per_facm1(isp)*phirbcp(im1,j,k,isp))&
                           &/(two*dx) 
                      if(isp.eq.1)then
                         slope_u(i) = (ubcp(ip1,j,k,1)-ubcp(im1,j,k,1))&
                              &/(two*dx) 
                      end if
#if 0                   
                      slope_phi(i) = slope_factor*slope_phi(i)*phi_ri
                      if(isp.eq.1) slope_u(i) = slope_factor*slope_u(i)*phi_ri
#endif
                      
                      if(isp.eq.1)then
!!$                From the cell i, one can get the following information at the interfaces (i-1/2) and (i+1/2)
!!$                (i-1/2) --> uplus stored at index i-1(im1)
!!$                (i+1/2) --> uminus stored at i
!!$                Uplus(xi+1/2) = P[U](i+1)|(xi+1/2) and
                         
!!$                Uminus(xi+1/2) = P[U](i)|(xi+1/2)
                         
                         uplus(i-1) = ubcp(i,j,k,1) - slope_u(i)*(dx/two) ! uplus(xi-1/2)
                         uminus(i) =  ubcp(i,j,k,1) + slope_u(i)*(dx/two) ! uminus(xi+1/2)
                      end if
                      U_plus(i-1) = phirbcp(i,j,k,isp) - slope_phi(i)*(dx/two)  ! Uplus(i-1/2)
                      U_minus(i) =  phirbcp(i,j,k,isp) + slope_phi(i)*(dx/two) ! Uminus(i+1/2)
                      
                   end do
                   
                   
                   do i = 0, nx
                      !im1 = i-1
                      
!!$ Evaluate the flux at an interface using the formula :
!!$           f(i+1/2) = 1/2[fplus(i+1/2) + fminus(i+1/2)] -1/2[ max(|uminus|,|uplus|)|(i+1/2){Uplus(i+1/2)-Uminus(i+1/2)}]

!!$           f(i-1/2) = 1/2[fplus(i-1/2) + fminus(i-1/2)] -1/2[ max(|uminus|,|uplus|)|(i-1/2){Uplus(i+1/2)-Uminus(i+1/2)}]

!!$ From the cell i, we can compute the following information:
!!$ At (i-1/2) --> fplus(i-1/2) stored at fdderiv(i-1) or fdderiv(im1)
!!$ At (i+1/2) --> fminus(i+1/2)stored at fdderiv(i) or fdderiv(im1)
                      
!!$                   fdderiv(im1,j,k,isp) = half*(uplus(im1)*U_plus(im1))&
!!$                        & + half*(uminus(im1)*U_minus(im1))
!!$
!!$                   max_speed = MAX(ABS(uminus(im1)), ABS(uplus(im1)))
!!$                   fdderiv(im1,j,k,isp) = fdderiv(im1,j,k,isp) - half&
!!$                        &*max_speed*(U_plus(im1)-U_minus(im1))

                      max_speed = MAX(ABS(uminus(i)), ABS(uplus(i)))
                      fdderiv(i,j,k,isp) = half*(uplus(i)*U_plus(i))&
                           & + half*(uminus(i)*U_minus(i))
                      fdderiv(i,j,k,isp) = fdderiv(i,j,k,isp) - half&
                           &*max_speed*(U_plus(i)-U_minus(i))
                      !if(i.ne.1)then
!!$ Except for cell 1 (due to PBC), if I am at cell index i, then I
                      !! am ensured that I now have the complete
                      !! information 
!!$ for interface (i-1/2).
                      
                      !end if

                   end do
                end do
             end do
          end do
       end if
          
       DO isp = 1, nspmx
          DO i = 1, nx !mx1
             do k = 1, mz
                do j = 1, my 
                   im1 = i-1
                   ip1 = i+1
                   
                   if(discr_scheme.eq."center")then
                      ur1phi(j,k) = (fdderiv(ip1,j,k,isp) - fdderiv(im1,j,k,isp))/(two*dx)
!!$                
                   else if(discr_scheme.eq."upwind")then
                      ur1phi(j,k) = (fdderiv(i,j,k,isp) - fdderiv(im1,j,k,isp))/dx
                   end if
                   
                end do
             end do
             
             call ff2rc(ur1phi, uf1phif)

             nlphif(i,:,:,isp) = nlphif(i,:,:,isp) + uf1phif(:,:)
          end DO
#if !PARALLEL
          nlphif(mx, :,:,isp) = nlphif(1,:,:,isp)/heat_ratio(isp)
#endif
       end DO
       phi_fluid_mean = zero 
       phi_solid_mean = zero 
       phimodmean = zero 
       phifmeanloc = zero
       phismeanloc = zero
       phimodmeanloc = zero
     count_neg = 0
       DO isp = 1, nspmx
#if !PARALLEL
          DO i = 1, nx!+1 !mx
#else
          DO i = 0, nx+1
#endif
             do k = 1, mz
                do j = 1, my
                   ubcp(i,j,k,isp) = phirbcp(i,j,k,isp)
                    if(fluid_atijk(i,j,k)) then 
                      if(phirbcp(i,j,k,isp).lt.zero) count_neg = count_neg+1
                    endif
                   if(i.gt.0.and.i.le.nx)then
                      if(j.le.my2) nlphif(i,j,k,isp) = -nlphif(i,j,k,isp)
                      if(fluid_atijk(i,j,k)) then 
                         phifmeanloc(isp) = phifmeanloc(isp) + ubcp(i,j,k,isp)
                      ELSE
                         phismeanloc(isp) = phismeanloc(isp)+ubcp(i,j,k,isp)
                      end if
                      phimodmeanloc(isp) = phimodmeanloc(isp) +  ubcp(i&
                           &,j,k,isp)
                   end if
                   !In nlphi, real transform of non linear term is stored in nlbc, therefore, here phirbc is stored in ubcp.
                end do
             end do
          end DO
#if !PARALLEL
          nlphif(mx,:,:,isp) = -nlphif(mx,:,:,isp)!/heat_ratio(isp)
          ubcp(mx,:,:,isp) = ubcp(1,:,:,isp)/heat_ratio(isp)
#endif
          
          GLOBAL_DOUBLE_SUM(phifmeanloc(isp),phi_fluid_mean(isp),1,decomp_group)
          GLOBAL_DOUBLE_SUM(phismeanloc(isp),phi_solid_mean(isp),1,decomp_group)
          !   GLOBAL_DOUBLE_SUM(phimodmeanloc(isp),phimodmean(isp),1,decomp_group)
       end DO
       phi_fluid_mean(1:nspmx) = phi_fluid_mean(1:nspmx)/(count_fluid)
       phi_solid_mean(1:nspmx) = phi_solid_mean(1:nspmx)/(count_solid)
       phimodmean = phimodmean/(mx1*my*mz)
       if(I_AM_NODE_ZERO)then
          WRITE(*,'(A26,3(2x,g17.8))') "PHI MEAN F and SF = ",  phi_fluid_mean(1:nspmx), phi_fluid_mean(1:nspmx)*(one-maxvolfrac)
               ! endif
             write(*,*)'there is somewrong if this value is not equal to 0', count_neg
       end if
       
       RETURN 
          
     END SUBROUTINE form_nlphi

     SUBROUTINE compute_phim_heat_ratio(output)!(velr,phi)
       Use nlmainarrays, Only : velr=>ubcp, phi=>nlbcp
       IMPLICIT NONE
       !real(prcn), DImension(:,:,:,:), Intent(in) :: velr,phi
       LOGICAL, Intent(in) :: output
       INTEGER :: i,j,k, isp,count_up,time_uphi=1
        CHARaCTER*80 :: FILENAME1 
       real(prcn) :: mean_theta, mean_velo,mean_utheta
       
       CHARACTER(LEN=80) :: formfile

       formfile='formatted'

    IF(iglobstep.eq.1)  OPEN(200,FILE=TRIM(RUN_NAME)//'_time_uphi.dat')

   !    FILENAME1 = TRIM(RUN_NAME)//'_timeuphi'//'.dat'

    !   CALL  RUN_TIME_FILE_OPENER(time_uphi,FILENAME1, formfile)

   ! endif  
       um = zero
       phim = zero
       countfl_plane = 0
       
       do i = 1, nx+1 !mx
          do k = 1, mz
             do j = 1, my
                if(output)then
                   if(fluid_atijk(i,j,k))then
                      do isp = 1, nspmx
                         phim(i,isp) = phim(i,isp) + velr(i,j,k,1)*phi(i,j,k,isp)
                      end do
                      um(i) = um(i) + velr(i,j,k,1)
                      countfl_plane(i) = countfl_plane(i) + 1
                   end if
                else
                   do isp = 1, nspmx
                      phim(i,isp) = phim(i,isp) + velr(i,j,k,1)*phi(i,j,k,isp)
                   end do
                   um(i) = um(i) + velr(i,j,k,1)
                   countfl_plane(i) = countfl_plane(i) + 1
                end if
             end do
          end do
          um(i) = um(i)/real(countfl_plane(i),prcn)

          do isp = 1, nspmx
             phim(i,isp) = phim(i,isp)/(um(i)*real(countfl_plane(i),prcn))
          end do
       end do
       if(I_AM_LAST_PROC)then
          do isp = 1, nspmx
             heat_ratio_new(isp) = one/phim(nx+1,isp)!phim(1,isp)/phim(nx+1,isp)!
          end do
       end if
       BROADCAST_DOUBLE(heat_ratio_new(1),nspmx,END_PROC,decomp_group)

 if(mod(iglobstep,10).eq.0) then
       mean_theta = zero
      mean_velo =zero
      mean_utheta  =zero
     count_up = zero

        do i = 1, nx !mx
          do k = 1, mz
             do j = 1, my
           if(fluid_atijk(i,j,k)) then
             count_up = count_up +1
            mean_theta = mean_theta + phi(i,j,k,1)/ phim(i,1)
            mean_velo =mean_velo + velr(i,j,k,1)
           endif
        enddo
        enddo
        enddo    

         mean_theta= mean_theta/count_up
         mean_velo =mean_velo/count_up
      do i = 1, nx !mx
      do k = 1, mz
      do j = 1, my
        if(fluid_atijk(i,j,k)) then
         mean_utheta = mean_utheta + ( velr(i,j,k,1)-mean_velo)*(phi(i,j,k,1)/phim(i,1)-mean_theta )
        endif
      enddo
      enddo
      enddo
            mean_utheta = mean_utheta / count_up/ufmean_des(1)

      
            !  OPEN(200,FILE=TRIM(RUN_NAME)//'_time_uphi.dat','keep')


                 write(200,*)t,mean_utheta    !!velr(1,j,k,1)-umean_vel(1) , phir(1,j,k,1)-mean_phi(1)
             !! close(200,status="keep")

  endif
      
       if(I_AM_NODE_ZERO)then
          Write(*,*)'HEAT RATIO@N-1 : ', heat_ratio(:), 'HEAT_RATIO@N: ',&
                     & heat_ratio_new(:)
          !Write(*,*)'umo: ', um(mx), 'umi: ', um(1)
          !Write(*,*) 'phimo: ', phim(mx), 'phimi: ', phim(1)
          !Write(*,*)'NLMEAN REQ:', (phim(mx)-phim(1))*um(1)
          !READ(*,*)
       end if
     END SUBROUTINE compute_phim_heat_ratio
     
     integer function sgn(a)
       implicit none
       REAL(prcn), INTENT(in) :: a
       if(a.lt.zero) then
          sgn = -1
       elseif(a.gt.zero)then
          sgn = 1
       else
          sgn = 0
       end if
     end function sgn
     
   END MODULE nl_allphi
   
