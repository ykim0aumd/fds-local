!> \brief Collection of routines to compute boundary conditions

MODULE WALL_ROUTINES

USE PRECISION_PARAMETERS
USE GLOBAL_CONSTANTS
USE MESH_POINTERS
USE DEVICE_VARIABLES, ONLY : PROPERTY,PROPERTY_TYPE

IMPLICIT NONE (TYPE,EXTERNAL)
PRIVATE

PUBLIC WALL_BC,TGA_ANALYSIS

TYPE(WALL_TYPE), POINTER :: WC
TYPE(CFACE_TYPE), POINTER :: CFA
TYPE(EXTERNAL_WALL_TYPE), POINTER :: EWC
TYPE(LAGRANGIAN_PARTICLE_TYPE), POINTER :: LP
TYPE(LAGRANGIAN_PARTICLE_CLASS_TYPE), POINTER :: LPC
TYPE(BOUNDARY_ONE_D_TYPE), POINTER :: ONE_D,ONE_D_BACK
TYPE(BOUNDARY_PROPS_TYPE), POINTER :: BP,BP_BACK
TYPE(BOUNDARY_COORD_TYPE), POINTER :: BC,BC_BACK
TYPE(SURFACE_TYPE), POINTER :: SF
TYPE(VENTS_TYPE), POINTER :: VT
TYPE(OMESH_TYPE), POINTER :: OM
TYPE(MESH_TYPE), POINTER :: MM
TYPE(MATERIAL_TYPE), POINTER :: ML
TYPE(PROPERTY_TYPE), POINTER :: PY
LOGICAL :: CALL_HT_1D

CONTAINS


!> \brief Main control routine for applying boundary conditions.
!>
!> \param T Current time (s)
!> \param DT Current time step (s)
!> \param NM Mesh number

SUBROUTINE WALL_BC(T,DT,NM)

USE COMP_FUNCTIONS, ONLY: CURRENT_TIME
USE SOOT_ROUTINES, ONLY: DEPOSITION_BC
REAL(EB) :: TNOW
REAL(EB), INTENT(IN) :: T,DT
INTEGER, INTENT(IN) :: NM

IF (LEVEL_SET_MODE==1) RETURN  ! No need for boundary conditions if the simulation is uncoupled fire spread only

TNOW=CURRENT_TIME()

CALL POINT_TO_MESH(NM)

! Compute the temperature TMP_F at all boundary cells, including PYROLYSIS and 1-D heat transfer

CALL THERMAL_BC(T,NM)

! Compute rho*D at WALL cells

CALL DIFFUSIVITY_BC

! Special boundary routines
IF (DEPOSITION .AND. .NOT.INITIALIZATION_PHASE) CALL DEPOSITION_BC(DT,NM)
IF (HVAC_SOLVE .AND. .NOT.INITIALIZATION_PHASE) CALL HVAC_BC

! Compute the species mass fractions, ZZ_F, at all boundary cells

CALL SPECIES_BC(T,DT,NM)

! Compute the density, RHO_F, at WALL cells only

CALL DENSITY_BC

T_USED(6)=T_USED(6)+CURRENT_TIME()-TNOW
END SUBROUTINE WALL_BC


!> \brief Thermal boundary conditions for all boundaries.
!>
!> \details One dimensional heat transfer and pyrolysis is done in PYROLYSIS.
!> Note also that gas phase values are assigned here to be used for all subsequent BCs.
!> \callgraph

SUBROUTINE THERMAL_BC(T,NM)

USE MATH_FUNCTIONS, ONLY: EVALUATE_RAMP
USE PHYSICAL_FUNCTIONS, ONLY : GET_SPECIFIC_GAS_CONSTANT,GET_SOLID_CONDUCTIVITY,GET_SOLID_RHOCBAR,&
                               GET_SOLID_ABSORPTION_COEFFICIENT,GET_SOLID_REFRACTIVE_INDEX
USE CC_SCALARS, ONLY : CFACE_THERMAL_GASVARS
REAL(EB), INTENT(IN) :: T
REAL(EB) :: DT_BC,DTMP,DT_BC_HT3D,TSI,UBAR,VBAR,WBAR,RAMP_FACTOR,TMP_G,RHO_G,ZZ_G(1:N_TRACKED_SPECIES),RSUM_G,MU_G
INTEGER  :: SURF_INDEX,IW,IP,ICF
INTEGER, INTENT(IN) :: NM
REAL(EB), POINTER, DIMENSION(:,:) :: PBAR_P
REAL(EB), POINTER, DIMENSION(:,:,:) :: UU=>NULL(),VV=>NULL(),WW=>NULL(),RHOP=>NULL(),OM_RHOP=>NULL(),OM_TMP=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP=>NULL()

IF (PREDICTOR) THEN
   UU => US
   VV => VS
   WW => WS
   RHOP => RHOS
   ZZP  => ZZS
   PBAR_P => PBAR_S
ELSE
   UU => U
   VV => V
   WW => W
   RHOP => RHO
   ZZP  => ZZ
   PBAR_P => PBAR
ENDIF

! For thermally-thick boundary conditions, set the flag to call the routine PYROLYSIS

CALL_HT_1D = .FALSE.
IF (.NOT.INITIALIZATION_PHASE .AND. CORRECTOR) THEN
   WALL_COUNTER = WALL_COUNTER + 1
   IF (WALL_COUNTER==WALL_INCREMENT) THEN
      DT_BC    = T - BC_CLOCK
      BC_CLOCK = T
      CALL_HT_1D = .TRUE.
      WALL_COUNTER = 0
   ENDIF
ENDIF

! Loop through all wall cells and apply heat transfer BCs

WALL_CELL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS
   WC=>WALL(IW)
   IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY .AND. .NOT.SOLID_HT3D) CYCLE WALL_CELL_LOOP
   SURF_INDEX = WC%SURF_INDEX
   SF => SURFACE(SURF_INDEX)
   ONE_D => BOUNDARY_ONE_D(WC%OD_INDEX)
   BC    => BOUNDARY_COORD(WC%BC_INDEX)
   TMP_G =  TMP(BC%IIG,BC%JJG,BC%KKG)
   RHO_G = RHOP(BC%IIG,BC%JJG,BC%KKG)
   ZZ_G(1:N_TRACKED_SPECIES) = ZZP(BC%IIG,BC%JJG,BC%KKG,1:N_TRACKED_SPECIES)
   RSUM_G  = RSUM(BC%IIG,BC%JJG,BC%KKG)
   MU_G    = MU(BC%IIG,BC%JJG,BC%KKG)
   IF (ABS(SF%T_IGN-T_BEGIN)<=SPACING(SF%T_IGN) .AND. SF%RAMP_INDEX(TIME_VELO)>=1) THEN
      TSI = T
   ELSE
      TSI = T-SF%T_IGN
   ENDIF
   RAMP_FACTOR = EVALUATE_RAMP(TSI,SF%RAMP_INDEX(TIME_VELO),TAU=SF%TAU(TIME_VELO))
   SELECT CASE(BC%IOR)
      CASE(1,-1)
         VBAR = 0.5_EB*(VV(BC%IIG,BC%JJG,BC%KKG)+VV(BC%IIG,BC%JJG-1,BC%KKG)) - SF%VEL_T(1)*RAMP_FACTOR
         WBAR = 0.5_EB*(WW(BC%IIG,BC%JJG,BC%KKG)+WW(BC%IIG,BC%JJG,BC%KKG-1)) - SF%VEL_T(2)*RAMP_FACTOR
         ONE_D%U_TANG = SQRT(VBAR**2+WBAR**2)
      CASE(2,-2)
         UBAR = 0.5_EB*(UU(BC%IIG,BC%JJG,BC%KKG)+UU(BC%IIG-1,BC%JJG,BC%KKG)) - SF%VEL_T(1)*RAMP_FACTOR
         WBAR = 0.5_EB*(WW(BC%IIG,BC%JJG,BC%KKG)+WW(BC%IIG,BC%JJG,BC%KKG-1)) - SF%VEL_T(2)*RAMP_FACTOR
         ONE_D%U_TANG = SQRT(UBAR**2+WBAR**2)
      CASE(3,-3)
         UBAR = 0.5_EB*(UU(BC%IIG,BC%JJG,BC%KKG)+UU(BC%IIG-1,BC%JJG,BC%KKG)) - SF%VEL_T(1)*RAMP_FACTOR
         VBAR = 0.5_EB*(VV(BC%IIG,BC%JJG,BC%KKG)+VV(BC%IIG,BC%JJG-1,BC%KKG)) - SF%VEL_T(2)*RAMP_FACTOR
         ONE_D%U_TANG = SQRT(UBAR**2+VBAR**2)
   END SELECT
   CALL CALCULATE_TMP_F(WALL_INDEX=IW)
   IF (SF%THERMAL_BC_INDEX==THERMALLY_THICK .AND. CALL_HT_1D) CALL SOLID_HEAT_TRANSFER_1D(NM,T,DT_BC,WALL_INDEX=IW)
ENDDO WALL_CELL_LOOP

! Loop through all CFACEs and apply heat transfer BCs

CFACE_LOOP: DO ICF=INTERNAL_CFACE_CELLS_LB+1,INTERNAL_CFACE_CELLS_LB+N_INTERNAL_CFACE_CELLS
   CFA=>CFACE(ICF)
   IF (CFA%BOUNDARY_TYPE==NULL_BOUNDARY .AND. .NOT.SOLID_HT3D) CYCLE CFACE_LOOP
   SURF_INDEX = CFA%SURF_INDEX
   SF => SURFACE(SURF_INDEX)
   ONE_D => BOUNDARY_ONE_D(CFA%OD_INDEX)
   ! Populate TMP_G, RHO_G, ZZ_G(:), RSUM_G, U_TANG
   CALL CFACE_THERMAL_GASVARS(ICF,ONE_D)
   TMP_G = CFA%TMP_G
   RHO_G = CFA%RHO_G
   ZZ_G  = CFA%ZZ_G
   RSUM_G  = CFA%RSUM_G
   MU_G  = CFA%MU_G
   CALL CALCULATE_TMP_F(CFACE_INDEX=ICF)
   IF (SF%THERMAL_BC_INDEX==THERMALLY_THICK .AND. CALL_HT_1D) CALL SOLID_HEAT_TRANSFER_1D(NM,T,DT_BC,CFACE_INDEX=ICF)
ENDDO CFACE_LOOP

! Loop through all particles and apply heat transfer BCs

IF (SOLID_PARTICLES) THEN
   DO IP = 1, NLP
      LP => LAGRANGIAN_PARTICLE(IP)
      LPC => LAGRANGIAN_PARTICLE_CLASS(LP%CLASS_INDEX)
      IF (LPC%SOLID_PARTICLE .OR. LPC%MASSLESS_TARGET) THEN  ! Target particles are included to get gas phase values
         SURF_INDEX = LPC%SURF_INDEX
         SF => SURFACE(SURF_INDEX)
         ONE_D => BOUNDARY_ONE_D(LP%OD_INDEX)
         BC => BOUNDARY_COORD(LP%BC_INDEX)
         TMP_G = TMP(BC%IIG,BC%JJG,BC%KKG)
         RHO_G = RHOP(BC%IIG,BC%JJG,BC%KKG)
         ZZ_G(1:N_TRACKED_SPECIES) = ZZP(BC%IIG,BC%JJG,BC%KKG,1:N_TRACKED_SPECIES)
         RSUM_G = RSUM(BC%IIG,BC%JJG,BC%KKG)
         MU_G   = MU(BC%IIG,BC%JJG,BC%KKG)
         UBAR = 0.5_EB*(UU(BC%IIG,BC%JJG,BC%KKG)+UU(BC%IIG-1,BC%JJG,BC%KKG)) - LP%U
         VBAR = 0.5_EB*(VV(BC%IIG,BC%JJG,BC%KKG)+VV(BC%IIG,BC%JJG-1,BC%KKG)) - LP%V
         WBAR = 0.5_EB*(WW(BC%IIG,BC%JJG,BC%KKG)+WW(BC%IIG,BC%JJG,BC%KKG-1)) - LP%W
         ONE_D%U_TANG = SQRT(UBAR**2+VBAR**2+WBAR**2)
         IF (LPC%SOLID_PARTICLE) CALL CALCULATE_TMP_F(PARTICLE_INDEX=IP)
         IF (SF%THERMAL_BC_INDEX==THERMALLY_THICK .AND. CALL_HT_1D) CALL SOLID_HEAT_TRANSFER_1D(NM,T,DT_BC,PARTICLE_INDEX=IP)
         IF (LPC%MASSLESS_TARGET) THEN
            PY => PROPERTY(LP%PROP_INDEX)
            IF (PY%HEAT_TRANSFER_COEFFICIENT>0._EB) THEN
               ONE_D%HEAT_TRANS_COEF = PY%HEAT_TRANSFER_COEFFICIENT
            ELSE
               ONE_D%HEAT_TRANS_COEF = HEAT_TRANSFER_COEFFICIENT(TMP_G-PY%GAUGE_TEMPERATURE,SF%H_FIXED,SURF_INDEX,&
                                       PARTICLE_INDEX_IN=IP)
            ENDIF
            ONE_D%Q_CON_F = ONE_D%HEAT_TRANS_COEF*(TMP_G-PY%GAUGE_TEMPERATURE)
         ENDIF
      ENDIF
   ENDDO
ENDIF

! *********************** UNDER CONSTRUCTION **************************
IF (.NOT.INITIALIZATION_PHASE .AND. SOLID_HT3D .AND. CORRECTOR) THEN
   WALL_COUNTER_HT3D = WALL_COUNTER_HT3D + 1
   IF (WALL_COUNTER_HT3D==WALL_INCREMENT_HT3D) THEN
      DT_BC_HT3D    = T - BC_CLOCK_HT3D
      BC_CLOCK_HT3D = T
      CALL SOLID_HEAT_TRANSFER_3D
      WALL_COUNTER_HT3D = 0
   ENDIF
ENDIF
! *********************************************************************

CONTAINS


!> \brief Calculate the surface temperature TMP_F
!>
!> \details Calculate the surface temperature TMP_F of either a rectangular WALL
!> cell, or an immersed CFACE cell, or a Lagrangian particle.
!> \param WALL_INDEX Optional WALL cell index
!> \param CFACE_INDEX Optional immersed boundary (CFACE) index
!> \param PARTICLE_INDEX Optional Lagrangian particle index

SUBROUTINE CALCULATE_TMP_F(WALL_INDEX,CFACE_INDEX,PARTICLE_INDEX)

USE PHYSICAL_FUNCTIONS, ONLY: GET_VISCOSITY
USE MATH_FUNCTIONS, ONLY: INTERPOLATE1D_UNIFORM, GET_SCALAR_FACE_VALUE
USE COMPLEX_GEOMETRY, ONLY : IBM_CGSC, IBM_SOLID

INTEGER, INTENT(IN), OPTIONAL :: WALL_INDEX,CFACE_INDEX,PARTICLE_INDEX
REAL(EB) :: ARO,FDERIV,QEXTRA,QNET,RAMP_FACTOR,RHO_G_2,RSUM_F,PBAR_F,TMP_OTHER_SOLID,TSI,UN, &
            RHO_ZZ_F(1:N_TOTAL_SCALARS),ZZ_GET(1:N_TRACKED_SPECIES), &
            RHO_OTHER,RHO_OTHER_2,RHO_ZZ_OTHER(1:N_TOTAL_SCALARS),RHO_ZZ_OTHER_2,RHO_ZZ_G,RHO_ZZ_G_2, &
            DDO,PBAR_G,PBAR_OTHER,DENOM,D_Z_N(0:I_MAX_TEMP),D_Z_G,D_Z_OTHER,TMP_OTHER, &
            MU_DNS_G,MU_DNS_OTHER,MU_OTHER,RHO_D,RHO_D_TURB,RHO_D_DZDN,RHO_D_DZDN_OTHER,RSUM_OTHER

LOGICAL :: SECOND_ORDER_INTERPOLATED_BOUNDARY,SOLID_OTHER,ATMOSPHERIC_INTERPOLATION,CC_SOLID_FLAG
INTEGER :: II,JJ,KK,IIG,JJG,KKG,IOR,IIO,JJO,KKO,N,ADCOUNT,ICG,ICO
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: OM_ZZP=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:) :: OM_MUP=>NULL()
REAL(EB), DIMENSION(0:3,0:3,0:3) :: U_TEMP,Z_TEMP,F_TEMP

SF  => SURFACE(SURF_INDEX)

IF (PRESENT(WALL_INDEX)) THEN
   WC=>WALL(WALL_INDEX)
   ONE_D => BOUNDARY_ONE_D(WC%OD_INDEX)
   BC => BOUNDARY_COORD(WC%BC_INDEX)
   II  = BC%II
   JJ  = BC%JJ
   KK  = BC%KK
ELSEIF (PRESENT(CFACE_INDEX)) THEN
   CFA=>CFACE(CFACE_INDEX)
   ONE_D => BOUNDARY_ONE_D(CFA%OD_INDEX)
   BC => BOUNDARY_COORD(CFA%BC_INDEX)
   KK  = CUT_FACE(CFA%CUT_FACE_IND1)%IJK(KAXIS) ! CUT_FACE type INBOUNDARY -> KK is under-laying Cartesian cell index.
ELSEIF (PRESENT(PARTICLE_INDEX)) THEN
   LP=>LAGRANGIAN_PARTICLE(PARTICLE_INDEX)
   ONE_D => BOUNDARY_ONE_D(LP%OD_INDEX)
   BC => BOUNDARY_COORD(LP%BC_INDEX)
ENDIF

IIG = BC%IIG
JJG = BC%JJG
KKG = BC%KKG
IOR = BC%IOR

! Compute surface temperature, TMP_F, and convective heat flux, Q_CON_F, for various boundary conditions

METHOD_OF_HEAT_TRANSFER: SELECT CASE(SF%THERMAL_BC_INDEX)

   CASE (NO_CONVECTION) METHOD_OF_HEAT_TRANSFER

      ONE_D%TMP_F  = TMP_G

   CASE (INFLOW_OUTFLOW) METHOD_OF_HEAT_TRANSFER  ! Only for WALL cells

      ! Base inflow/outflow decision on velocity component with same predictor/corrector attribute

      SELECT CASE(IOR)
         CASE( 1); UN =  UU(II,JJ,KK)
         CASE(-1); UN = -UU(II-1,JJ,KK)
         CASE( 2); UN =  VV(II,JJ,KK)
         CASE(-2); UN = -VV(II,JJ-1,KK)
         CASE( 3); UN =  WW(II,JJ,KK)
         CASE(-3); UN = -WW(II,JJ,KK-1)
         CASE DEFAULT; UN = 0._EB
      END SELECT

      IF (UN>TWO_EPSILON_EB) THEN  ! Assume the flow is coming into the domain
         ONE_D%TMP_F = TMP_0(KK)
         IF (WC%VENT_INDEX>0) THEN
            VT => VENTS(WC%VENT_INDEX)
            IF (VT%TMP_EXTERIOR>0._EB) THEN
               TSI = T - T_BEGIN
               ONE_D%TMP_F = TMP_0(KK) + EVALUATE_RAMP(TSI,VT%TMP_EXTERIOR_RAMP_INDEX)*(VT%TMP_EXTERIOR-TMP_0(KK))
            ENDIF
         ENDIF
         ONE_D%ZZ_F(1:N_TRACKED_SPECIES)=SPECIES_MIXTURE(1:N_TRACKED_SPECIES)%ZZ0
      ELSE
         ONE_D%TMP_F = TMP_G
         ONE_D%ZZ_F(1:N_TRACKED_SPECIES) = ZZ_G(1:N_TRACKED_SPECIES)
      ENDIF

      ! Ghost cell values

      TMP(II,JJ,KK) = ONE_D%TMP_F
      ZZP(II,JJ,KK,1:N_TRACKED_SPECIES) = ONE_D%ZZ_F(1:N_TRACKED_SPECIES)
      ZZ_GET(1:N_TRACKED_SPECIES) = MAX(0._EB,ZZP(II,JJ,KK,1:N_TRACKED_SPECIES))
      CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM(II,JJ,KK))
      RHOP(II,JJ,KK) = PBAR_P(KK,ONE_D%PRESSURE_ZONE)/(RSUM(II,JJ,KK)*TMP(II,JJ,KK))

      ONE_D%Q_CON_F = 2._EB*ONE_D%K_G*(TMP_G-ONE_D%TMP_F)*ONE_D%RDN

   CASE (SPECIFIED_TEMPERATURE) METHOD_OF_HEAT_TRANSFER

      IF (ABS(ONE_D%T_IGN-T_BEGIN) <= SPACING(ONE_D%T_IGN) .AND. SF%RAMP_INDEX(TIME_TEMP)>=1) THEN
         TSI = T
      ELSE
         TSI = T - ONE_D%T_IGN
      ENDIF

      IF (ONE_D%U_NORMAL>TWO_EPSILON_EB) THEN
         ONE_D%TMP_F = TMP_G
      ELSEIF (SF%TMP_FRONT>0._EB) THEN
         ONE_D%TMP_F = TMP_0(KKG) + EVALUATE_RAMP(TSI,SF%RAMP_INDEX(TIME_TEMP),TAU=SF%TAU(TIME_TEMP))*(SF%TMP_FRONT-TMP_0(KKG))
      ELSE
         ONE_D%TMP_F = TMP_0(KKG)
      ENDIF

      DTMP = TMP_G - ONE_D%TMP_F
      IF (PRESENT(WALL_INDEX)) THEN
         ONE_D%HEAT_TRANS_COEF = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SURF_INDEX,WALL_INDEX_IN=WALL_INDEX)
      ELSEIF (PRESENT(CFACE_INDEX)) THEN
         ONE_D%HEAT_TRANS_COEF = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SURF_INDEX,CFACE_INDEX_IN=CFACE_INDEX)
      ELSEIF (PRESENT(PARTICLE_INDEX)) THEN
         ONE_D%HEAT_TRANS_COEF = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SURF_INDEX,PARTICLE_INDEX_IN=PARTICLE_INDEX)
      ENDIF
      ONE_D%Q_CON_F = ONE_D%HEAT_TRANS_COEF*DTMP

   CASE (CONVECTIVE_FLUX_BC,NET_FLUX_BC) METHOD_OF_HEAT_TRANSFER

      IF (ABS(ONE_D%T_IGN-T_BEGIN)<= SPACING(ONE_D%T_IGN) .AND. SF%RAMP_INDEX(TIME_HEAT)>=1) THEN
         TSI = T
      ELSE
         TSI = T - ONE_D%T_IGN
      ENDIF
      TMP_OTHER = ONE_D%TMP_F
      RAMP_FACTOR = EVALUATE_RAMP(TSI,SF%RAMP_INDEX(TIME_HEAT),TAU=SF%TAU(TIME_HEAT))
      IF (SF%SET_H) THEN
         ONE_D%Q_CON_F = -RAMP_FACTOR*SF%CONVECTIVE_HEAT_FLUX*ONE_D%AREA_ADJUST
         ONE_D%HEAT_TRANS_COEF = ONE_D%Q_CON_F/(TMP_G-TMP_OTHER+TWO_EPSILON_EB)
      ELSE
         IF (SF%THERMAL_BC_INDEX==NET_FLUX_BC) THEN
            QNET = -RAMP_FACTOR*SF%NET_HEAT_FLUX*ONE_D%AREA_ADJUST
         ELSE
            QNET = -RAMP_FACTOR*SF%CONVECTIVE_HEAT_FLUX*ONE_D%AREA_ADJUST
         ENDIF
         ADCOUNT = 0
         ADLOOP: DO
            ADCOUNT = ADCOUNT + 1
            DTMP = TMP_G - TMP_OTHER
            IF (ABS(QNET) > 0._EB .AND. ABS(DTMP) <TWO_EPSILON_EB) DTMP=1._EB
            IF (PRESENT(WALL_INDEX)) THEN
               ONE_D%HEAT_TRANS_COEF = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SURF_INDEX,WALL_INDEX_IN=WALL_INDEX)
            ELSEIF (PRESENT(CFACE_INDEX)) THEN
               ONE_D%HEAT_TRANS_COEF = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SURF_INDEX,CFACE_INDEX_IN=CFACE_INDEX)
            ELSEIF (PRESENT(PARTICLE_INDEX)) THEN
               ONE_D%HEAT_TRANS_COEF = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SURF_INDEX,PARTICLE_INDEX_IN=PARTICLE_INDEX)
            ENDIF
            IF (RADIATION .AND. SF%THERMAL_BC_INDEX/=CONVECTIVE_FLUX_BC) THEN
               QEXTRA = ONE_D%HEAT_TRANS_COEF*DTMP + ONE_D%Q_RAD_IN - ONE_D%EMISSIVITY * SIGMA * TMP_OTHER ** 4 - QNET
               FDERIV = -ONE_D%HEAT_TRANS_COEF -  4._EB * ONE_D%EMISSIVITY * SIGMA * TMP_OTHER ** 3
            ELSE
               QEXTRA = ONE_D%HEAT_TRANS_COEF*DTMP - QNET
               FDERIV = -ONE_D%HEAT_TRANS_COEF
            ENDIF
            IF (ABS(FDERIV) > TWO_EPSILON_EB) TMP_OTHER = TMP_OTHER - QEXTRA / FDERIV
            IF (ABS(QEXTRA) < 1.E-10_EB .OR. ADCOUNT > 20) THEN
               ONE_D%TMP_F = MAX(TMPMIN,MIN(TMPMAX,TMP_OTHER))
               EXIT ADLOOP
            ELSE
               ONE_D%TMP_F = MAX(TMPMIN,MIN(TMPMAX,TMP_OTHER))
               CYCLE ADLOOP
            ENDIF
         ENDDO ADLOOP
         ONE_D%Q_CON_F = ONE_D%HEAT_TRANS_COEF*DTMP
      ENDIF

   CASE (INTERPOLATED_BC) METHOD_OF_HEAT_TRANSFER  ! Only for EXTERNAL_WALL_CELLs

      EWC => EXTERNAL_WALL(WALL_INDEX)
      OM => OMESH(EWC%NOM)
      IF (PREDICTOR) THEN
         OM_RHOP => OM%RHOS
         OM_ZZP => OM%ZZS
      ELSE
         OM_RHOP => OM%RHO
         OM_ZZP => OM%ZZ
      ENDIF
      IF (SOLID_HT3D) OM_TMP => OM%TMP
      MM => MESHES(EWC%NOM)

      ! Gather data from other mesh

      RHO_OTHER=0._EB
      RHO_ZZ_OTHER=0._EB
      TMP_OTHER_SOLID=0._EB
      SOLID_OTHER=.FALSE.
      DDO=1._EB

      DO KKO=EWC%KKO_MIN,EWC%KKO_MAX
         DO JJO=EWC%JJO_MIN,EWC%JJO_MAX
            DO IIO=EWC%IIO_MIN,EWC%IIO_MAX
               SELECT CASE(IOR)
                  CASE( 1)
                     ARO = MIN(1._EB , (MM%DY(JJO)*MM%DZ(KKO))/(DY(JJ)*DZ(KK)) )
                  CASE(-1)
                     ARO = MIN(1._EB , (MM%DY(JJO)*MM%DZ(KKO))/(DY(JJ)*DZ(KK)) )
                  CASE( 2)
                     ARO = MIN(1._EB , (MM%DX(IIO)*MM%DZ(KKO))/(DX(II)*DZ(KK)) )
                  CASE(-2)
                     ARO = MIN(1._EB , (MM%DX(IIO)*MM%DZ(KKO))/(DX(II)*DZ(KK)) )
                  CASE( 3)
                     ARO = MIN(1._EB , (MM%DX(IIO)*MM%DY(JJO))/(DX(II)*DY(JJ)) )
                     DDO = (DZ(KK)+DZ(KKG))/(MM%DZ(KKO)+DZ(KKG))
                  CASE(-3)
                     ARO = MIN(1._EB , (MM%DX(IIO)*MM%DY(JJO))/(DX(II)*DY(JJ)) )
                     DDO = (DZ(KK)+DZ(KKG))/(MM%DZ(KKO)+DZ(KKG))
               END SELECT
               RHO_OTHER = RHO_OTHER + ARO*OM_RHOP(IIO,JJO,KKO)      ! average multiple face values
               RHO_ZZ_OTHER(1:N_TOTAL_SCALARS) = RHO_ZZ_OTHER(1:N_TOTAL_SCALARS) &
                  + ARO*OM_RHOP(IIO,JJO,KKO)*OM_ZZP(IIO,JJO,KKO,1:N_TOTAL_SCALARS)
               IF (SOLID_HT3D) THEN
                  TMP_OTHER_SOLID = TMP_OTHER_SOLID + ARO*OM_TMP(IIO,JJO,KKO)
                  ICO = MM%CELL_INDEX(IIO,JJO,KKO)
                  IF (MM%SOLID(ICO)) SOLID_OTHER=.TRUE.
               ENDIF
            ENDDO
         ENDDO
      ENDDO

      ! Determine if there are 4 equally sized cells spanning the interpolated boundary

      SECOND_ORDER_INTERPOLATED_BOUNDARY = .FALSE.
      CC_SOLID_FLAG = .FALSE.
      IF (ABS(EWC%AREA_RATIO-1._EB)<0.01_EB) THEN
         IIO = EWC%IIO_MIN
         JJO = EWC%JJO_MIN
         KKO = EWC%KKO_MIN
         SELECT CASE(IOR)
            CASE( 1) ; ICG = CELL_INDEX(IIG+1,JJG,KKG) ; ICO = MM%CELL_INDEX(IIO-1,JJO,KKO)
            CASE(-1) ; ICG = CELL_INDEX(IIG-1,JJG,KKG) ; ICO = MM%CELL_INDEX(IIO+1,JJO,KKO)
            CASE( 2) ; ICG = CELL_INDEX(IIG,JJG+1,KKG) ; ICO = MM%CELL_INDEX(IIO,JJO-1,KKO)
            CASE(-2) ; ICG = CELL_INDEX(IIG,JJG-1,KKG) ; ICO = MM%CELL_INDEX(IIO,JJO+1,KKO)
            CASE( 3) ; ICG = CELL_INDEX(IIG,JJG,KKG+1) ; ICO = MM%CELL_INDEX(IIO,JJO,KKO-1)
            CASE(-3) ; ICG = CELL_INDEX(IIG,JJG,KKG-1) ; ICO = MM%CELL_INDEX(IIO,JJO,KKO+1)
         END SELECT
         IF (CC_IBM) THEN ! Test if one of surrounding cells is IBM_SOLID.
            IF(CCVAR(IIG,JJG,KKG,IBM_CGSC)==IBM_SOLID .OR. CCVAR(II,JJ,KK,IBM_CGSC)==IBM_SOLID) CC_SOLID_FLAG = .TRUE.
         ENDIF
         IF (.NOT.SOLID(ICG) .AND. .NOT.MM%SOLID(ICO) .AND. .NOT.CC_SOLID_FLAG) SECOND_ORDER_INTERPOLATED_BOUNDARY = .TRUE.
      ENDIF

      ! Density

      ATMOSPHERIC_INTERPOLATION = .FALSE.
      IF (USE_ATMOSPHERIC_INTERPOLATION .AND. STRATIFICATION .AND. ABS(DDO-1._EB)>0.01_EB .AND. ABS(IOR)==3) &
         ATMOSPHERIC_INTERPOLATION = .TRUE.

      IF (ATMOSPHERIC_INTERPOLATION) THEN
         ! interp or extrap RHO_OTHER for jump in vertical grid resolution, linear in temperature to match heat flux in divg
         PBAR_G = PBAR_P(KKG,ONE_D%PRESSURE_ZONE)
         PBAR_OTHER = EVALUATE_RAMP(MM%ZC(EWC%KKO_MIN),I_RAMP_P0_Z)
         ZZ_GET(1:N_TRACKED_SPECIES) = MAX(0._EB,MIN(1._EB,RHO_ZZ_OTHER(1:N_TOTAL_SCALARS)/RHO_OTHER))
         CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM(II,JJ,KK))
         DENOM = PBAR_G/RHO_G/RSUM_G + DDO*(PBAR_OTHER/RHO_OTHER/RSUM(II,JJ,KK) - PBAR_G/RHO_G/RSUM_G)
         RHOP(II,JJ,KK) = PBAR_P(KK,ONE_D%PRESSURE_ZONE)/RSUM(II,JJ,KK)/DENOM
      ELSE
         RHOP(II,JJ,KK) = RHO_OTHER
      ENDIF

      RHO_G_2        = RHO_G ! first-order
      RHO_OTHER      = RHOP(II,JJ,KK)
      RHO_OTHER_2    = RHOP(II,JJ,KK)

      SELECT CASE(IOR)
         CASE( 1)
            IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
               RHO_G_2 = RHOP(IIG+1,JJG,KKG)
               RHO_OTHER_2 = OM_RHOP(IIO-1,JJO,KKO)
            ENDIF
            Z_TEMP(0:3,1,1) = (/RHO_OTHER_2,RHO_OTHER,RHO_G,RHO_G_2/)
            U_TEMP(1,1,1) = UU(II,JJ,KK)
            CALL GET_SCALAR_FACE_VALUE(U_TEMP,Z_TEMP,F_TEMP,1,1,1,1,1,1,1,I_FLUX_LIMITER)
            ONE_D%RHO_F = F_TEMP(1,1,1)
         CASE(-1)
            IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
               RHO_G_2 = RHOP(IIG-1,JJG,KKG)
               RHO_OTHER_2 = OM_RHOP(IIO+1,JJO,KKO)
            ENDIF
            Z_TEMP(0:3,1,1) = (/RHO_G_2,RHO_G,RHO_OTHER,RHO_OTHER_2/)
            U_TEMP(1,1,1) = UU(II-1,JJ,KK)
            CALL GET_SCALAR_FACE_VALUE(U_TEMP,Z_TEMP,F_TEMP,1,1,1,1,1,1,1,I_FLUX_LIMITER)
            ONE_D%RHO_F = F_TEMP(1,1,1)
         CASE( 2)
            IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
               RHO_G_2 = RHOP(IIG,JJG+1,KKG)
               RHO_OTHER_2 = OM_RHOP(IIO,JJO-1,KKO)
            ENDIF
            Z_TEMP(1,0:3,1) = (/RHO_OTHER_2,RHO_OTHER,RHO_G,RHO_G_2/)
            U_TEMP(1,1,1) = VV(II,JJ,KK)
            CALL GET_SCALAR_FACE_VALUE(U_TEMP,Z_TEMP,F_TEMP,1,1,1,1,1,1,2,I_FLUX_LIMITER)
            ONE_D%RHO_F = F_TEMP(1,1,1)
         CASE(-2)
            IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
               RHO_G_2 = RHOP(IIG,JJG-1,KKG)
               RHO_OTHER_2 = OM_RHOP(IIO,JJO+1,KKO)
            ENDIF
            Z_TEMP(1,0:3,1) = (/RHO_G_2,RHO_G,RHO_OTHER,RHO_OTHER_2/)
            U_TEMP(1,1,1) = VV(II,JJ-1,KK)
            CALL GET_SCALAR_FACE_VALUE(U_TEMP,Z_TEMP,F_TEMP,1,1,1,1,1,1,2,I_FLUX_LIMITER)
            ONE_D%RHO_F = F_TEMP(1,1,1)
         CASE( 3)
            IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
               RHO_G_2 = RHOP(IIG,JJG,KKG+1)
               RHO_OTHER_2 = OM_RHOP(IIO,JJO,KKO-1)
            ENDIF
            Z_TEMP(1,1,0:3) = (/RHO_OTHER_2,RHO_OTHER,RHO_G,RHO_G_2/)
            U_TEMP(1,1,1) = WW(II,JJ,KK)
            CALL GET_SCALAR_FACE_VALUE(U_TEMP,Z_TEMP,F_TEMP,1,1,1,1,1,1,3,I_FLUX_LIMITER)
            ONE_D%RHO_F = F_TEMP(1,1,1)
         CASE(-3)
            IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
               RHO_G_2 = RHOP(IIG,JJG,KKG-1)
               RHO_OTHER_2 = OM_RHOP(IIO,JJO,KKO+1)
            ENDIF
            Z_TEMP(1,1,0:3) = (/RHO_G_2,RHO_G,RHO_OTHER,RHO_OTHER_2/)
            U_TEMP(1,1,1) = WW(II,JJ,KK-1)
            CALL GET_SCALAR_FACE_VALUE(U_TEMP,Z_TEMP,F_TEMP,1,1,1,1,1,1,3,I_FLUX_LIMITER)
            ONE_D%RHO_F = F_TEMP(1,1,1)
      END SELECT

      ! Species and temperature

      SINGLE_SPEC_IF: IF (N_TOTAL_SCALARS > 1) THEN
         SPECIES_LOOP: DO N=1,N_TOTAL_SCALARS

            RHO_ZZ_G = RHO_G*ZZ_G(N)
            RHO_ZZ_G_2 = RHO_ZZ_G ! first-order (default)
            RHO_ZZ_OTHER_2 = RHO_ZZ_OTHER(N)

            SELECT CASE(IOR)
               CASE( 1)
                  IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
                     RHO_ZZ_G_2 = RHOP(IIG+1,JJG,KKG)*ZZP(IIG+1,JJG,KKG,N)
                     RHO_ZZ_OTHER_2 = OM_RHOP(IIO-1,JJO,KKO)*OM_ZZP(IIO-1,JJO,KKO,N)
                  ENDIF
                  Z_TEMP(0:3,1,1) = (/RHO_ZZ_OTHER_2,RHO_ZZ_OTHER(N),RHO_ZZ_G,RHO_ZZ_G_2/)
                  U_TEMP(1,1,1) = UU(II,JJ,KK)
                  CALL GET_SCALAR_FACE_VALUE(U_TEMP,Z_TEMP,F_TEMP,1,1,1,1,1,1,1,I_FLUX_LIMITER)
                  RHO_ZZ_F(N) = F_TEMP(1,1,1)
                  PBAR_F = PBAR_P(KKG,ONE_D%PRESSURE_ZONE)
               CASE(-1)
                  IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
                     RHO_ZZ_G_2 = RHOP(IIG-1,JJG,KKG)*ZZP(IIG-1,JJG,KKG,N)
                     RHO_ZZ_OTHER_2 = OM_RHOP(IIO+1,JJO,KKO)*OM_ZZP(IIO+1,JJO,KKO,N)
                  ENDIF
                  Z_TEMP(0:3,1,1) = (/RHO_ZZ_G_2,RHO_ZZ_G,RHO_ZZ_OTHER(N),RHO_ZZ_OTHER_2/)
                  U_TEMP(1,1,1) = UU(II-1,JJ,KK)
                  CALL GET_SCALAR_FACE_VALUE(U_TEMP,Z_TEMP,F_TEMP,1,1,1,1,1,1,1,I_FLUX_LIMITER)
                  RHO_ZZ_F(N) = F_TEMP(1,1,1)
                  PBAR_F = PBAR_P(KKG,ONE_D%PRESSURE_ZONE)
               CASE( 2)
                  IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
                     RHO_ZZ_G_2 = RHOP(IIG,JJG+1,KKG)*ZZP(IIG,JJG+1,KKG,N)
                     RHO_ZZ_OTHER_2 = OM_RHOP(IIO,JJO-1,KKO)*OM_ZZP(IIO,JJO-1,KKO,N)
                  ENDIF
                  Z_TEMP(1,0:3,1) = (/RHO_ZZ_OTHER_2,RHO_ZZ_OTHER(N),RHO_ZZ_G,RHO_ZZ_G_2/)
                  U_TEMP(1,1,1) = VV(II,JJ,KK)
                  CALL GET_SCALAR_FACE_VALUE(U_TEMP,Z_TEMP,F_TEMP,1,1,1,1,1,1,2,I_FLUX_LIMITER)
                  RHO_ZZ_F(N) = F_TEMP(1,1,1)
                  PBAR_F = PBAR_P(KKG,ONE_D%PRESSURE_ZONE)
               CASE(-2)
                  IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
                     RHO_ZZ_G_2 = RHOP(IIG,JJG-1,KKG)*ZZP(IIG,JJG-1,KKG,N)
                     RHO_ZZ_OTHER_2 = OM_RHOP(IIO,JJO+1,KKO)*OM_ZZP(IIO,JJO+1,KKO,N)
                  ENDIF
                  Z_TEMP(1,0:3,1) = (/RHO_ZZ_G_2,RHO_ZZ_G,RHO_ZZ_OTHER(N),RHO_ZZ_OTHER_2/)
                  U_TEMP(1,1,1) = VV(II,JJ-1,KK)
                  CALL GET_SCALAR_FACE_VALUE(U_TEMP,Z_TEMP,F_TEMP,1,1,1,1,1,1,2,I_FLUX_LIMITER)
                  RHO_ZZ_F(N) = F_TEMP(1,1,1)
                  PBAR_F = PBAR_P(KKG,ONE_D%PRESSURE_ZONE)
               CASE( 3)
                  IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
                     RHO_ZZ_G_2 = RHOP(IIG,JJG,KKG+1)*ZZP(IIG,JJG,KKG+1,N)
                     RHO_ZZ_OTHER_2 = OM_RHOP(IIO,JJO,KKO-1)*OM_ZZP(IIO,JJO,KKO-1,N)
                  ENDIF
                  Z_TEMP(1,1,0:3) = (/RHO_ZZ_OTHER_2,RHO_ZZ_OTHER(N),RHO_ZZ_G,RHO_ZZ_G_2/)
                  U_TEMP(1,1,1) = WW(II,JJ,KK)
                  CALL GET_SCALAR_FACE_VALUE(U_TEMP,Z_TEMP,F_TEMP,1,1,1,1,1,1,3,I_FLUX_LIMITER)
                  RHO_ZZ_F(N) = F_TEMP(1,1,1)
                  PBAR_F = (PBAR_P(KK,ONE_D%PRESSURE_ZONE)*DZ(KKG) + PBAR_P(KKG,ONE_D%PRESSURE_ZONE)*DZ(KK)) / (DZ(KK)+DZ(KKG))
               CASE(-3)
                  IF (SECOND_ORDER_INTERPOLATED_BOUNDARY) THEN
                     RHO_ZZ_G_2 = RHOP(IIG,JJG,KKG-1)*ZZP(IIG,JJG,KKG-1,N)
                     RHO_ZZ_OTHER_2 = OM_RHOP(IIO,JJO,KKO+1)*OM_ZZP(IIO,JJO,KKO+1,N)
                  ENDIF
                  Z_TEMP(1,1,0:3) = (/RHO_ZZ_G_2,RHO_ZZ_G,RHO_ZZ_OTHER(N),RHO_ZZ_OTHER_2/)
                  U_TEMP(1,1,1) = WW(II,JJ,KK-1)
                  CALL GET_SCALAR_FACE_VALUE(U_TEMP,Z_TEMP,F_TEMP,1,1,1,1,1,1,3,I_FLUX_LIMITER)
                  RHO_ZZ_F(N) = F_TEMP(1,1,1)
                  PBAR_F = (PBAR_P(KK,ONE_D%PRESSURE_ZONE)*DZ(KKG) + PBAR_P(KKG,ONE_D%PRESSURE_ZONE)*DZ(KK)) / (DZ(KK)+DZ(KKG))
            END SELECT
         ENDDO SPECIES_LOOP

         ! ghost cell value of temperature
         ZZP(II,JJ,KK,1:N_TOTAL_SCALARS) = MAX(0._EB,MIN(1._EB,RHO_ZZ_OTHER(1:N_TOTAL_SCALARS)/RHO_OTHER))
         ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(II,JJ,KK,1:N_TRACKED_SPECIES)
         CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM(II,JJ,KK))
         TMP(II,JJ,KK) = PBAR_P(KK,ONE_D%PRESSURE_ZONE)/(RSUM(II,JJ,KK)*RHOP(II,JJ,KK))

         ! face value of temperature
         IF (ATMOSPHERIC_INTERPOLATION) THEN
            ONE_D%TMP_F = (TMP(II,JJ,KK)*DZ(KKG) + TMP(IIG,JJG,KKG)*DZ(KK)) / (DZ(KK)+DZ(KKG))
            ONE_D%ZZ_F(1:N_TOTAL_SCALARS) = (ZZP(II,JJ,KK,1:N_TOTAL_SCALARS)*DZ(KKG) + ZZP(IIG,JJG,KKG,1:N_TOTAL_SCALARS)*DZ(KK)) &
                                          / (DZ(KK)+DZ(KKG))
            ZZ_GET(1:N_TRACKED_SPECIES) = ONE_D%ZZ_F(1:N_TRACKED_SPECIES)
            CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM_F)
            ONE_D%RHO_F = PBAR_F/(RSUM_F*ONE_D%TMP_F)
         ELSE
            ONE_D%ZZ_F(1:N_TOTAL_SCALARS) = MAX(0._EB,MIN(1._EB,RHO_ZZ_F(1:N_TOTAL_SCALARS)/ONE_D%RHO_F))
            ZZ_GET(1:N_TRACKED_SPECIES) = ONE_D%ZZ_F(1:N_TRACKED_SPECIES)
            CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM_F)
            ONE_D%TMP_F = PBAR_F/(RSUM_F*ONE_D%RHO_F)
         ENDIF

         ! flux match species diffusive flux at interpolated boundaries with mesh refinement
         COARSE_MESH_IF: IF (EWC%NIC>1) THEN
            ! we are on coarse mesh gas cell (G) and need to average fluxes from the fine mesh (OTHER)
            OM_MUP => OM%MU
            SPECIES_LOOP_2: DO N=1,N_TOTAL_SCALARS
               SELECT CASE(SIM_MODE)
                  CASE(DNS_MODE,LES_MODE)
                     D_Z_N = D_Z(:,N)
                     CALL INTERPOLATE1D_UNIFORM(LBOUND(D_Z_N,1),D_Z_N,TMP_G,D_Z_G)
                     IF (SIM_MODE==LES_MODE) CALL GET_VISCOSITY(ZZ_GET,MU_DNS_G,TMP_G)
               END SELECT
               RHO_D_DZDN_OTHER = 0._EB
               KKO_LOOP: DO KKO=EWC%KKO_MIN,EWC%KKO_MAX
                  JJO_LOOP: DO JJO=EWC%JJO_MIN,EWC%JJO_MAX
                     IIO_LOOP: DO IIO=EWC%IIO_MIN,EWC%IIO_MAX
                        MU_OTHER = OM_MUP(IIO,JJO,KKO)
                        RHO_OTHER = OM_RHOP(IIO,JJO,KKO)
                        MODE_SELECT: SELECT CASE(SIM_MODE)
                           CASE DEFAULT
                              RHO_D = MAX(0._EB, 0.5_EB*(MU_OTHER+MU_G) )*RSC
                           CASE(DNS_MODE,LES_MODE)
                              D_Z_N = D_Z(:,N)
                              ZZ_GET(1:N_TRACKED_SPECIES) = OM_ZZP(IIO,JJO,KKO,1:N_TRACKED_SPECIES)
                              CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM_OTHER)
                              PBAR_OTHER = EVALUATE_RAMP(MM%ZC(KKO),I_RAMP_P0_Z)
                              TMP_OTHER = PBAR_OTHER/(RSUM_OTHER*RHO_OTHER)
                              CALL INTERPOLATE1D_UNIFORM(LBOUND(D_Z_N,1),D_Z_N,TMP_OTHER,D_Z_OTHER)
                              RHO_D_TURB = 0._EB
                              IF (SIM_MODE==LES_MODE) THEN
                                 CALL GET_VISCOSITY(ZZ_GET,MU_DNS_OTHER,TMP_OTHER)
                                 RHO_D_TURB = 0.5_EB*(MU_OTHER-MU_DNS_OTHER + MU_G-MU_DNS_G)*RSC
                              ENDIF
                              RHO_D = 0.5_EB*( RHO_OTHER*D_Z_OTHER + RHO_G*D_Z_G ) + RHO_D_TURB
                        END SELECT MODE_SELECT
                        SELECT CASE(IOR)
                           CASE( 1)
                              ARO = MM%DY(JJO)*MM%DZ(KKO)/(DY(JJ)*DZ(KK))
                              RHO_D_DZDN = RHO_D*(ZZP(IIG,JJG,KKG,N)-OM_ZZP(IIO,JJO,KKO,N))*MM%RDXN(IIO)
                           CASE(-1)
                              ARO = MM%DY(JJO)*MM%DZ(KKO)/(DY(JJ)*DZ(KK))
                              RHO_D_DZDN = RHO_D*(ZZP(IIG,JJG,KKG,N)-OM_ZZP(IIO,JJO,KKO,N))*MM%RDXN(IIO-1)
                           CASE( 2)
                              ARO = MM%DX(IIO)*MM%DZ(KKO)/(DX(II)*DZ(KK))
                              RHO_D_DZDN = RHO_D*(ZZP(IIG,JJG,KKG,N)-OM_ZZP(IIO,JJO,KKO,N))*MM%RDYN(JJO)
                           CASE(-2)
                              ARO = MM%DX(IIO)*MM%DZ(KKO)/(DX(II)*DZ(KK))
                              RHO_D_DZDN = RHO_D*(ZZP(IIG,JJG,KKG,N)-OM_ZZP(IIO,JJO,KKO,N))*MM%RDYN(JJO-1)
                           CASE( 3)
                              ARO = MM%DX(IIO)*MM%DY(JJO)/(DX(II)*DY(JJ))
                              RHO_D_DZDN = RHO_D*(ZZP(IIG,JJG,KKG,N)-OM_ZZP(IIO,JJO,KKO,N))*MM%RDZN(KKO)
                           CASE(-3)
                              ARO = MM%DX(IIO)*MM%DY(JJO)/(DX(II)*DY(JJ))
                              RHO_D_DZDN = RHO_D*(ZZP(IIG,JJG,KKG,N)-OM_ZZP(IIO,JJO,KKO,N))*MM%RDZN(KKO-1)
                        END SELECT
                        ! average multiple face values
                        RHO_D_DZDN_OTHER = RHO_D_DZDN_OTHER + ARO*RHO_D_DZDN
                     ENDDO IIO_LOOP
                  ENDDO JJO_LOOP
               ENDDO KKO_LOOP
               ! store for use in divg
               ONE_D%RHO_D_DZDN_F(N) =  RHO_D_DZDN_OTHER
            ENDDO SPECIES_LOOP_2
            IF (SIM_MODE==DNS_MODE .OR. SIM_MODE==LES_MODE) THEN
               N=MAXLOC(ONE_D%ZZ_F(1:N_TRACKED_SPECIES),1)
               ONE_D%RHO_D_DZDN_F(N) = -(SUM(ONE_D%RHO_D_DZDN_F(1:N_TRACKED_SPECIES))-ONE_D%RHO_D_DZDN_F(N))
            ENDIF
         ENDIF COARSE_MESH_IF

      ELSE SINGLE_SPEC_IF
         ONE_D%ZZ_F(1) = 1._EB
         TMP(II,JJ,KK) = PBAR_P(KK,ONE_D%PRESSURE_ZONE)/(RSUM0*RHOP(II,JJ,KK))
         SELECT CASE(IOR)
            CASE DEFAULT
               PBAR_F = PBAR_P(KKG,ONE_D%PRESSURE_ZONE)
            CASE (-3,3)
               PBAR_F = (PBAR_P(KK,ONE_D%PRESSURE_ZONE)*DZ(KKG) + PBAR_P(KKG,ONE_D%PRESSURE_ZONE)*DZ(KK)) / (DZ(KK)+DZ(KKG))
         END SELECT
         IF (ATMOSPHERIC_INTERPOLATION) THEN
            ONE_D%TMP_F = (TMP(II,JJ,KK)*DZ(KKG) + TMP(IIG,JJG,KKG)*DZ(KK)) / (DZ(KK)+DZ(KKG))
            ONE_D%RHO_F = PBAR_F/(RSUM0*ONE_D%TMP_F)
         ELSE
            ONE_D%TMP_F = PBAR_F/(RSUM0*ONE_D%RHO_F)
         ENDIF
      ENDIF SINGLE_SPEC_IF

      IF (SOLID_HT3D) THEN
         IF (SOLID_OTHER) TMP(II,JJ,KK) = TMP_OTHER_SOLID
      ENDIF

      ONE_D%Q_CON_F = 0._EB ! no convective heat transfer at interpolated boundary

END SELECT METHOD_OF_HEAT_TRANSFER

END SUBROUTINE CALCULATE_TMP_F


SUBROUTINE SOLID_HEAT_TRANSFER_3D

! Solves the 3D heat conduction equation internal to OBSTs.

REAL(EB) :: DT_SUB,T_SUB,K_S,K_S_M,K_S_P,TMP_F,TMP_S,RDN,HTC,TMP_OTHER,RAMP_FACTOR,&
            QNET,TSI,FDERIV,QEXTRA,K_S_MAX,VN_HT3D,R_K_S,TMP_I,TH_EST4,FO_EST3,&
            RHO_GET(N_MATL),K_GET,K_OTHER,RHOCBAR_S,VC,VSRVC_LOC,RDS,KDTDN_S,KAPPA_S,K_R,REFRACTIVE_INDEX_S
INTEGER  :: II,JJ,KK,I,J,K,IOR,IC,ICM,ICP,IIG,JJG,KKG,ADCOUNT,IIO,JJO,KKO,NOM,N_INT_CELLS,NN,ITER,ICO
LOGICAL :: CONT_MATL_PROP,IS_STABLE_DT_SUB
INTEGER, PARAMETER :: N_JACOBI_ITERATIONS=1,SURFACE_HEAT_FLUX_MODEL=1
REAL(EB), PARAMETER :: DT_SUB_MIN_HT3D=1.E-9_EB
REAL(EB), POINTER, DIMENSION(:) :: Q_CON_F_SUB=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:) :: KDTDX=>NULL(),KDTDY=>NULL(),KDTDZ=>NULL(),TMP_NEW=>NULL(),KP=>NULL(),&
                                       VSRVC_X=>NULL(),VSRVC_Y=>NULL(),VSRVC_Z=>NULL(),VSRVC=>NULL()
TYPE(OBSTRUCTION_TYPE), POINTER :: OB=>NULL(),OBM=>NULL(),OBP=>NULL()
TYPE(MESH_TYPE), POINTER :: OM=>NULL()
TYPE(SURFACE_TYPE), POINTER :: MS=>NULL()

! Initialize verification tests

IF (ICYC==1) THEN
   SELECT CASE(HT3D_TEST)
      CASE(1); CALL CRANK_TEST_1(1)
      CASE(2); CALL CRANK_TEST_1(2)
      CASE(3); CALL CRANK_TEST_1(3)
   END SELECT
ENDIF

KDTDX=>WORK1; KDTDX=0._EB
KDTDY=>WORK2; KDTDY=0._EB
KDTDZ=>WORK3; KDTDZ=0._EB
TMP_NEW=>WORK4
KP=>WORK5; KP=0._EB
! CAUTION: work arrays also used in MT3D
VSRVC_X=>WORK6; VSRVC_X=1._EB
VSRVC_Y=>WORK7; VSRVC_Y=1._EB
VSRVC_Z=>WORK8; VSRVC_Z=1._EB
VSRVC  =>WORK9; VSRVC  =1._EB

Q_CON_F_SUB=>WALL_WORK1
Q_CON_F_SUB=0._EB

DT_SUB = DT_BC_HT3D
T_SUB = 0._EB

SUBSTEP_LOOP: DO WHILE ( ABS(T_SUB-DT_BC_HT3D)>TWO_EPSILON_EB )
   DT_SUB  = MIN(DT_SUB,DT_BC_HT3D-T_SUB)
   K_S_MAX = 0._EB
   VN_HT3D = 0._EB

   IS_STABLE_DT_SUB = .FALSE.
   TMP_UPDATE_LOOP: DO WHILE (.NOT.IS_STABLE_DT_SUB)

      TMP_NEW=TMP
      JACOBI_ITERATION_LOOP: DO ITER=1,N_JACOBI_ITERATIONS

         ! compute material thermal conductivity
         K_LOOP: DO K=1,KBAR
            J_LOOP: DO J=1,JBAR
               I_LOOP: DO I=1,IBAR
                  IC = CELL_INDEX(I,J,K);              IF (.NOT.SOLID(IC)) CYCLE
                  OB => OBSTRUCTION(OBST_INDEX_C(IC)); IF (.NOT.OB%HT3D)   CYCLE
                  IF (OB%MATL_INDEX>0) THEN
                     CALL GET_SOLID_CONDUCTIVITY(KP(I,J,K),TMP_NEW(I,J,K),OPT_MATL_INDEX=OB%MATL_INDEX)
                  ELSEIF (OB%MATL_SURF_INDEX>0) THEN
                     MS => SURFACE(OB%MATL_SURF_INDEX)
                     IF (TWO_D) THEN
                        VC = DX(I)*DZ(K)
                     ELSE
                        VC = DX(I)*DY(J)*DZ(K)
                     ENDIF
                     VSRVC(I,J,K) = 0._EB
                     DO NN=1,MS%N_MATL
                        ML => MATERIAL(MS%MATL_INDEX(NN))
                        VSRVC(I,J,K) = VSRVC(I,J,K) + OB%RHO(I,J,K,NN)/ML%RHO_S
                     ENDDO
                     IF (VSRVC(I,J,K)>TWO_EPSILON_EB) THEN
                        RHO_GET(1:MS%N_MATL) = OB%RHO(I,J,K,1:MS%N_MATL) / VSRVC(I,J,K)
                     ELSE
                        RHO_GET(1:MS%N_MATL) = 0._EB
                     ENDIF
                     CALL GET_SOLID_CONDUCTIVITY(KP(I,J,K),TMP_NEW(I,J,K),OPT_SURF_INDEX=OB%MATL_SURF_INDEX,OPT_RHO_IN=RHO_GET)
                     IF (MS%INTERNAL_RADIATION) THEN
                        CALL GET_SOLID_ABSORPTION_COEFFICIENT(KAPPA_S,OB%MATL_SURF_INDEX,RHO_GET)
                        CALL GET_SOLID_REFRACTIVE_INDEX(REFRACTIVE_INDEX_S,OB%MATL_SURF_INDEX,RHO_GET)
                        K_R = 16._EB*(REFRACTIVE_INDEX_S**2)*SIGMA*(TMP_NEW(I,J,K)**3) / (3._EB*KAPPA_S)
                        KP(I,J,K) = KP(I,J,K) + K_R
                     ENDIF
                     ! solid volume to cell volume ratio
                     SELECT CASE(ABS(OB%PYRO3D_IOR))
                        CASE DEFAULT
                           ! isotropic shrinking and swelling
                           IF (TWO_D) THEN
                              VSRVC_X(I,J,K) = VSRVC(I,J,K)**0.5_EB
                              VSRVC_Y(I,J,K) = 1._EB
                              VSRVC_Z(I,J,K) = VSRVC_X(I,J,K)
                           ELSE
                              VSRVC_X(I,J,K) = VSRVC(I,J,K)**ONTH
                              VSRVC_Y(I,J,K) = VSRVC_X(I,J,K)
                              VSRVC_Z(I,J,K) = VSRVC_X(I,J,K)
                           ENDIF
                        CASE(1)
                           VSRVC_X(I,J,K) = VSRVC(I,J,K)
                           VSRVC_Y(I,J,K) = 1._EB
                           VSRVC_Z(I,J,K) = 1._EB
                        CASE(2)
                           VSRVC_X(I,J,K) = 1._EB
                           VSRVC_Y(I,J,K) = VSRVC(I,J,K)
                           VSRVC_Z(I,J,K) = 1._EB
                        CASE(3)
                           VSRVC_X(I,J,K) = 1._EB
                           VSRVC_Y(I,J,K) = 1._EB
                           VSRVC_Z(I,J,K) = VSRVC(I,J,K)
                     END SELECT
                  ENDIF
               ENDDO I_LOOP
            ENDDO J_LOOP
         ENDDO K_LOOP

         KP_WALL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS
            WC => WALL(IW)
            IF (WC%BOUNDARY_TYPE/=NULL_BOUNDARY) CYCLE KP_WALL_LOOP
            BC => BOUNDARY_COORD(WC%BC_INDEX)

            II = BC%II
            JJ = BC%JJ
            KK = BC%KK

            EWC=>EXTERNAL_WALL(IW)
            NOM=EWC%NOM
            IF (NOM<1) CYCLE KP_WALL_LOOP
            OM=>MESHES(NOM)

            K_OTHER = 0._EB
            DO KKO=EWC%KKO_MIN,EWC%KKO_MAX
               DO JJO=EWC%JJO_MIN,EWC%JJO_MAX
                  EWC_IIO_LOOP: DO IIO=EWC%IIO_MIN,EWC%IIO_MAX

                     IC = OM%CELL_INDEX(IIO,JJO,KKO);           IF (.NOT.OM%SOLID(IC)) CYCLE EWC_IIO_LOOP
                     OB => OM%OBSTRUCTION(OM%OBST_INDEX_C(IC)); IF (.NOT.OB%HT3D) CYCLE EWC_IIO_LOOP
                     TMP_OTHER = OMESH(NOM)%TMP(IIO,JJO,KKO)

                     K_GET = 0._EB
                     IF (OB%MATL_INDEX>0) THEN
                        CALL GET_SOLID_CONDUCTIVITY(K_GET,TMP_OTHER,OPT_MATL_INDEX=OB%MATL_INDEX)
                     ELSEIF (OB%MATL_SURF_INDEX>0) THEN
                        MS => SURFACE(OB%MATL_SURF_INDEX)
                        VSRVC_LOC = 0._EB
                        DO NN=1,SURFACE(OB%MATL_SURF_INDEX)%N_MATL
                           ML => MATERIAL(SURFACE(OB%MATL_SURF_INDEX)%MATL_INDEX(NN))
                           VSRVC_LOC = VSRVC_LOC + OB%RHO(IIO,JJO,KKO,NN)/ML%RHO_S
                        ENDDO
                        RHO_GET(1:MS%N_MATL) = OB%RHO(IIO,JJO,KKO,1:MS%N_MATL) / VSRVC_LOC
                        CALL GET_SOLID_CONDUCTIVITY(K_GET,TMP_OTHER,OPT_SURF_INDEX=OB%MATL_SURF_INDEX,OPT_RHO_IN=RHO_GET)
                        IF (MS%INTERNAL_RADIATION) THEN
                           CALL GET_SOLID_ABSORPTION_COEFFICIENT(KAPPA_S,OB%MATL_SURF_INDEX,RHO_GET)
                           CALL GET_SOLID_REFRACTIVE_INDEX(REFRACTIVE_INDEX_S,OB%MATL_SURF_INDEX,RHO_GET)
                           K_R = 16._EB*(REFRACTIVE_INDEX_S**2)*SIGMA*(TMP_OTHER**3) / (3._EB*KAPPA_S)
                           K_GET = K_GET + K_R
                        ENDIF
                     ENDIF
                     K_OTHER = K_OTHER + K_GET

                  ENDDO EWC_IIO_LOOP
               ENDDO
            ENDDO
            N_INT_CELLS = (EWC%IIO_MAX-EWC%IIO_MIN+1) * (EWC%JJO_MAX-EWC%JJO_MIN+1) * (EWC%KKO_MAX-EWC%KKO_MIN+1)
            KP(II,JJ,KK) = K_OTHER/REAL(N_INT_CELLS,EB)

         ENDDO KP_WALL_LOOP

         ! build heat flux vectors
         K_LOOP_2: DO K=1,KBAR
            J_LOOP_2: DO J=1,JBAR
               I_LOOP_2: DO I=0,IBAR
                  ICM = CELL_INDEX(I,J,K)
                  ICP = CELL_INDEX(I+1,J,K)
                  IF (.NOT.(SOLID(ICM).AND.SOLID(ICP))) CYCLE

                  OBM => OBSTRUCTION(OBST_INDEX_C(ICM))
                  OBP => OBSTRUCTION(OBST_INDEX_C(ICP))
                  ! At present OBST_INDEX_C is not defined for ghost cells.
                  ! This means that:
                  !    1. continuous material properties will be assumed at a mesh boundary
                  !    2. we assume that if either OBM%HT3D .OR. OBP%HT3D we should process the boundary
                  IF (.NOT.(OBM%HT3D.OR.OBP%HT3D)) CYCLE

                  K_S_M = KP(I,J,K)
                  K_S_P = KP(I+1,J,K)

                  IF (K_S_M<TWO_EPSILON_EB .OR. K_S_P<TWO_EPSILON_EB) THEN
                     KDTDX(I,J,K) = 0._EB
                     CYCLE
                  ENDIF

                  ! determine if we have continuous material properties
                  CONT_MATL_PROP=.TRUE.
                  IF (OBM%MATL_INDEX>0 .AND. OBP%MATL_INDEX>0 .AND. OBM%MATL_INDEX/=OBP%MATL_INDEX) THEN
                     CONT_MATL_PROP=.FALSE.
                  ELSEIF (OBM%MATL_SURF_INDEX>0 .AND. OBP%MATL_SURF_INDEX>0 .AND. OBM%MATL_SURF_INDEX/=OBP%MATL_SURF_INDEX) THEN
                     CONT_MATL_PROP=.FALSE.
                  ELSEIF (OBM%MATL_INDEX>0 .AND. OBP%MATL_SURF_INDEX>0) THEN
                     CONT_MATL_PROP=.FALSE.
                  ELSEIF (OBM%MATL_SURF_INDEX>0 .AND. OBP%MATL_INDEX>0) THEN
                     CONT_MATL_PROP=.FALSE.
                  ENDIF

                  IF (CONT_MATL_PROP) THEN
                     ! use linear average from inverse lever rule
                     K_S = ( K_S_M*DX(I+1) + K_S_P*DX(I) )/( DX(I) + DX(I+1) )
                     K_S_MAX = MAX(K_S_MAX,K_S)
                     KDTDX(I,J,K) = K_S*(TMP_NEW(I+1,J,K)-TMP_NEW(I,J,K))*2._EB/(DX(I+1)*VSRVC_X(I+1,J,K)+DX(I)*VSRVC_X(I,J,K))
                  ELSE
                     ! for discontinuous material properties maintain continuity of flux, C0 continuity of temperature
                     ! (allow C1 discontinuity of temperature due to jump in thermal properties across interface)
                     R_K_S = K_S_P/K_S_M * DX(I)/DX(I+1) * VSRVC_X(I,J,K)/VSRVC_X(I+1,J,K)
                     TMP_I = (TMP_NEW(I,J,K) + R_K_S*TMP_NEW(I+1,J,K))/(1._EB + R_K_S) ! interface temperature
                     !! KDTDX(I,J,K) = K_S_P * (TMP_NEW(I+1,J,K)-TMP_I) * 2._EB/(DX(I+1)*VSRVC_X(I+1,J,K)) !! should be identical
                     KDTDX(I,J,K) = K_S_M * (TMP_I-TMP_NEW(I,J,K)) * 2._EB/(DX(I)*VSRVC_X(I,J,K))
                     K_S_MAX = MAX(K_S_MAX,MAX(K_S_M,K_S_P))
                  ENDIF
               ENDDO I_LOOP_2
            ENDDO J_LOOP_2
         ENDDO K_LOOP_2
         TWO_D_IF: IF (.NOT.TWO_D) THEN
            DO K=1,KBAR
               DO J=0,JBAR
                  DO I=1,IBAR
                     ICM = CELL_INDEX(I,J,K)
                     ICP = CELL_INDEX(I,J+1,K)
                     IF (.NOT.(SOLID(ICM).AND.SOLID(ICP))) CYCLE
                     OBM => OBSTRUCTION(OBST_INDEX_C(ICM))
                     OBP => OBSTRUCTION(OBST_INDEX_C(ICP))
                     IF (.NOT.(OBM%HT3D.OR.OBP%HT3D)) CYCLE

                     K_S_M = KP(I,J,K)
                     K_S_P = KP(I,J+1,K)

                     IF (K_S_M<TWO_EPSILON_EB .OR. K_S_P<TWO_EPSILON_EB) THEN
                        KDTDY(I,J,K) = 0._EB
                        CYCLE
                     ENDIF

                     CONT_MATL_PROP=.TRUE.
                     IF (OBM%MATL_INDEX>0 .AND. OBP%MATL_INDEX>0 .AND. OBM%MATL_INDEX/=OBP%MATL_INDEX) THEN
                        CONT_MATL_PROP=.FALSE.
                     ELSEIF (OBM%MATL_SURF_INDEX>0 .AND. OBP%MATL_SURF_INDEX>0 .AND. OBM%MATL_SURF_INDEX/=OBP%MATL_SURF_INDEX) THEN
                        CONT_MATL_PROP=.FALSE.
                     ELSEIF (OBM%MATL_INDEX>0 .AND. OBP%MATL_SURF_INDEX>0) THEN
                        CONT_MATL_PROP=.FALSE.
                     ELSEIF (OBM%MATL_SURF_INDEX>0 .AND. OBP%MATL_INDEX>0) THEN
                        CONT_MATL_PROP=.FALSE.
                     ENDIF

                     IF (CONT_MATL_PROP) THEN
                        K_S = ( K_S_M*DY(J+1) + K_S_P*DY(J) )/( DY(J) + DY(J+1) )
                        K_S_MAX = MAX(K_S_MAX,K_S)
                        KDTDY(I,J,K) = K_S*(TMP_NEW(I,J+1,K)-TMP_NEW(I,J,K))*2._EB/(DY(J+1)*VSRVC_Y(I,J+1,K)+DY(J)*VSRVC_Y(I,J,K))
                     ELSE
                        R_K_S = K_S_P/K_S_M * DY(J)/DY(J+1) * VSRVC_Y(I,J,K)/VSRVC_Y(I,J+1,K)
                        TMP_I = (TMP_NEW(I,J,K) + R_K_S*TMP_NEW(I,J+1,K))/(1._EB + R_K_S)
                        KDTDY(I,J,K) = K_S_M * (TMP_I-TMP_NEW(I,J,K)) * 2._EB/(DY(J)*VSRVC_Y(I,J,K))
                        K_S_MAX = MAX(K_S_MAX,MAX(K_S_M,K_S_P))
                     ENDIF
                  ENDDO
               ENDDO
            ENDDO
         ELSE TWO_D_IF
            KDTDY(I,J,K) = 0._EB
         ENDIF TWO_D_IF
         DO K=0,KBAR
            DO J=1,JBAR
               DO I=1,IBAR
                  ICM = CELL_INDEX(I,J,K)
                  ICP = CELL_INDEX(I,J,K+1)
                  IF (.NOT.(SOLID(ICM).AND.SOLID(ICP))) CYCLE
                  OBM => OBSTRUCTION(OBST_INDEX_C(ICM))
                  OBP => OBSTRUCTION(OBST_INDEX_C(ICP))
                  IF (.NOT.(OBM%HT3D.OR.OBP%HT3D)) CYCLE

                  K_S_M = KP(I,J,K)
                  K_S_P = KP(I,J,K+1)

                  IF (K_S_M<TWO_EPSILON_EB .OR. K_S_P<TWO_EPSILON_EB) THEN
                     KDTDZ(I,J,K) = 0._EB
                     CYCLE
                  ENDIF

                  CONT_MATL_PROP=.TRUE.
                  IF (OBM%MATL_INDEX>0 .AND. OBP%MATL_INDEX>0 .AND. OBM%MATL_INDEX/=OBP%MATL_INDEX) THEN
                     CONT_MATL_PROP=.FALSE.
                  ELSEIF (OBM%MATL_SURF_INDEX>0 .AND. OBP%MATL_SURF_INDEX>0 .AND. OBM%MATL_SURF_INDEX/=OBP%MATL_SURF_INDEX) THEN
                     CONT_MATL_PROP=.FALSE.
                  ELSEIF (OBM%MATL_INDEX>0 .AND. OBP%MATL_SURF_INDEX>0) THEN
                     CONT_MATL_PROP=.FALSE.
                  ELSEIF (OBM%MATL_SURF_INDEX>0 .AND. OBP%MATL_INDEX>0) THEN
                     CONT_MATL_PROP=.FALSE.
                  ENDIF

                  IF (CONT_MATL_PROP) THEN
                     K_S = ( K_S_M*DZ(K+1) + K_S_P*DZ(K) )/( DZ(K) + DZ(K+1) )
                     K_S_MAX = MAX(K_S_MAX,K_S)
                     KDTDZ(I,J,K) = K_S*(TMP_NEW(I,J,K+1)-TMP_NEW(I,J,K))*2._EB/(DZ(K+1)*VSRVC_Z(I,J,K+1)+DZ(K)*VSRVC_Z(I,J,K))
                  ELSE
                     R_K_S = K_S_P/K_S_M * DZ(K)/DZ(K+1) * VSRVC_Z(I,J,K)/VSRVC_Z(I,J,K+1)
                     TMP_I = (TMP_NEW(I,J,K) + R_K_S*TMP_NEW(I,J,K+1))/(1._EB + R_K_S)
                     KDTDZ(I,J,K) = K_S_M * (TMP_I-TMP_NEW(I,J,K)) * 2._EB/(DZ(K)*VSRVC_Z(I,J,K))
                     K_S_MAX = MAX(K_S_MAX,MAX(K_S_M,K_S_P))
                  ENDIF
               ENDDO
            ENDDO
         ENDDO

         ! build fluxes on boundaries of INTERNAL WALL CELLS

         HT3D_WALL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS

            WC => WALL(IW)
            IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY) CYCLE HT3D_WALL_LOOP

            ONE_D => BOUNDARY_ONE_D(WC%OD_INDEX)
            SURF_INDEX = WC%SURF_INDEX
            SF => SURFACE(SURF_INDEX)
            BC => BOUNDARY_COORD(WC%BC_INDEX)
            II  = BC%II
            JJ  = BC%JJ
            KK  = BC%KK
            IIG = BC%IIG
            JJG = BC%JJG
            KKG = BC%KKG
            IOR = BC%IOR

            IC = CELL_INDEX(II,JJ,KK)
            IF (.NOT.SOLID(IC)) CYCLE HT3D_WALL_LOOP

            IF (.NOT.EXTERIOR(IC)) THEN
               OB => OBSTRUCTION(OBST_INDEX_C(IC))
            ELSE
               EWC => EXTERNAL_WALL(IW)
               IF (EWC%NOM==0) CYCLE HT3D_WALL_LOOP
               IIO = EWC%IIO_MIN
               JJO = EWC%JJO_MIN
               KKO = EWC%KKO_MIN
               ICO = MESHES(EWC%NOM)%CELL_INDEX(IIO,JJO,KKO)
               OB => MESHES(EWC%NOM)%OBSTRUCTION(MESHES(EWC%NOM)%OBST_INDEX_C(ICO))
            ENDIF

            IF (.NOT.OB%HT3D  ) CYCLE HT3D_WALL_LOOP

            MATL_IF: IF (OB%MATL_INDEX>0) THEN
               CALL GET_SOLID_CONDUCTIVITY(K_S,ONE_D%TMP_F,OPT_MATL_INDEX=OB%MATL_INDEX)
            ELSEIF (OB%MATL_SURF_INDEX>0) THEN
               MS => SURFACE(OB%MATL_SURF_INDEX)
               IF (VSRVC(II,JJ,KK)>TWO_EPSILON_EB) THEN
                  RHO_GET(1:MS%N_MATL) = OB%RHO(II,JJ,KK,1:MS%N_MATL) / VSRVC(II,JJ,KK)
               ELSE
                  RHO_GET(1:MS%N_MATL) = 0._EB
               ENDIF
               CALL GET_SOLID_CONDUCTIVITY(K_S,ONE_D%TMP_F,OPT_SURF_INDEX=OB%MATL_SURF_INDEX,OPT_RHO_IN=RHO_GET)
               IF (MS%INTERNAL_RADIATION) THEN
                  CALL GET_SOLID_ABSORPTION_COEFFICIENT(KAPPA_S,OB%MATL_SURF_INDEX,RHO_GET)
                  CALL GET_SOLID_REFRACTIVE_INDEX(REFRACTIVE_INDEX_S,OB%MATL_SURF_INDEX,RHO_GET)
                  K_R = 16._EB*(REFRACTIVE_INDEX_S**2)*SIGMA*(ONE_D%TMP_F**3) / (3._EB*KAPPA_S)
                  K_S = K_S + K_R
               ENDIF
            ENDIF MATL_IF
            K_S_MAX = MAX(K_S_MAX,K_S)

            METHOD_OF_HEAT_TRANSFER: SELECT CASE(SF%THERMAL_BC_INDEX)

               CASE DEFAULT METHOD_OF_HEAT_TRANSFER ! includes SPECIFIED_TEMPERATURE

                  SELECT CASE(IOR)
                     CASE( 1); KDTDX(II,JJ,KK)   = K_S * 2._EB*(ONE_D%TMP_F-TMP_NEW(II,JJ,KK))*RDX(II)/VSRVC_X(II,JJ,KK)
                     CASE(-1); KDTDX(II-1,JJ,KK) = K_S * 2._EB*(TMP_NEW(II,JJ,KK)-ONE_D%TMP_F)*RDX(II)/VSRVC_X(II,JJ,KK)
                     CASE( 2); KDTDY(II,JJ,KK)   = K_S * 2._EB*(ONE_D%TMP_F-TMP_NEW(II,JJ,KK))*RDY(JJ)/VSRVC_Y(II,JJ,KK)
                     CASE(-2); KDTDY(II,JJ-1,KK) = K_S * 2._EB*(TMP_NEW(II,JJ,KK)-ONE_D%TMP_F)*RDY(JJ)/VSRVC_Y(II,JJ,KK)
                     CASE( 3); KDTDZ(II,JJ,KK)   = K_S * 2._EB*(ONE_D%TMP_F-TMP_NEW(II,JJ,KK))*RDZ(KK)/VSRVC_Z(II,JJ,KK)
                     CASE(-3); KDTDZ(II,JJ,KK-1) = K_S * 2._EB*(TMP_NEW(II,JJ,KK)-ONE_D%TMP_F)*RDZ(KK)/VSRVC_Z(II,JJ,KK)
                  END SELECT

               CASE (NET_FLUX_BC) METHOD_OF_HEAT_TRANSFER
                  SELECT CASE(IOR)
                     CASE( 1); KDTDX(II,JJ,KK)   = -SF%NET_HEAT_FLUX*ONE_D%AREA_ADJUST
                     CASE(-1); KDTDX(II-1,JJ,KK) =  SF%NET_HEAT_FLUX*ONE_D%AREA_ADJUST
                     CASE( 2); KDTDY(II,JJ,KK)   = -SF%NET_HEAT_FLUX*ONE_D%AREA_ADJUST
                     CASE(-2); KDTDY(II,JJ-1,KK) =  SF%NET_HEAT_FLUX*ONE_D%AREA_ADJUST
                     CASE( 3); KDTDZ(II,JJ,KK)   = -SF%NET_HEAT_FLUX*ONE_D%AREA_ADJUST
                     CASE(-3); KDTDZ(II,JJ,KK-1) =  SF%NET_HEAT_FLUX*ONE_D%AREA_ADJUST
                  END SELECT

                  SOLID_PHASE_ONLY_IF: IF (SOLID_PHASE_ONLY) THEN
                     SELECT CASE(IOR)
                        CASE( 1); ONE_D%TMP_F = TMP_NEW(II,JJ,KK) + KDTDX(II,JJ,KK)   / (K_S*2._EB*RDX(II)/VSRVC_X(II,JJ,KK))
                        CASE(-1); ONE_D%TMP_F = TMP_NEW(II,JJ,KK) - KDTDX(II-1,JJ,KK) / (K_S*2._EB*RDX(II)/VSRVC_X(II,JJ,KK))
                        CASE( 2); ONE_D%TMP_F = TMP_NEW(II,JJ,KK) + KDTDY(II,JJ,KK)   / (K_S*2._EB*RDY(JJ)/VSRVC_Y(II,JJ,KK))
                        CASE(-2); ONE_D%TMP_F = TMP_NEW(II,JJ,KK) - KDTDY(II,JJ-1,KK) / (K_S*2._EB*RDY(JJ)/VSRVC_Y(II,JJ,KK))
                        CASE( 3); ONE_D%TMP_F = TMP_NEW(II,JJ,KK) + KDTDZ(II,JJ,KK)   / (K_S*2._EB*RDZ(KK)/VSRVC_Z(II,JJ,KK))
                        CASE(-3); ONE_D%TMP_F = TMP_NEW(II,JJ,KK) - KDTDZ(II,JJ,KK-1) / (K_S*2._EB*RDZ(KK)/VSRVC_Z(II,JJ,KK))
                     END SELECT
                  ELSE
                     ! Special case where the gas temperature is fixed by the user
                     IF (ASSUMED_GAS_TEMPERATURE > 0._EB) TMP_G = TMPA + &
                        EVALUATE_RAMP(T-T_BEGIN,I_RAMP_AGT)*(ASSUMED_GAS_TEMPERATURE-TMPA)
                     TMP_F = ONE_D%TMP_F
                     TMP_OTHER = TMP_F
                     DTMP = TMP_G - TMP_F
                     IF (ABS(ONE_D%T_IGN-T_BEGIN)<= SPACING(ONE_D%T_IGN) .AND. SF%RAMP_INDEX(TIME_HEAT)>=1) THEN
                        TSI = T
                     ELSE
                        TSI = T - ONE_D%T_IGN
                     ENDIF
                     RAMP_FACTOR = EVALUATE_RAMP(TSI,SF%RAMP_INDEX(TIME_HEAT),TAU=SF%TAU(TIME_HEAT))
                     QNET = -RAMP_FACTOR*SF%NET_HEAT_FLUX*ONE_D%AREA_ADJUST
                     ADCOUNT = 0
                     ADLOOP: DO
                        ADCOUNT = ADCOUNT + 1
                        DTMP = TMP_G - TMP_OTHER
                        IF (ABS(QNET) > 0._EB .AND. ABS(DTMP) <TWO_EPSILON_EB) DTMP=1._EB
                        ONE_D%HEAT_TRANS_COEF = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SURF_INDEX,WALL_INDEX_IN=IW)
                        HTC = ONE_D%HEAT_TRANS_COEF
                        IF (RADIATION) THEN
                           QEXTRA = HTC*DTMP + ONE_D%Q_RAD_IN - ONE_D%EMISSIVITY*SIGMA*TMP_OTHER**4 - QNET + ONE_D%Q_CONDENSE
                           FDERIV = -HTC - 4._EB*ONE_D%EMISSIVITY*SIGMA*TMP_OTHER**3
                        ELSE
                           QEXTRA = HTC*DTMP - QNET  + ONE_D%Q_CONDENSE
                           FDERIV = -HTC
                        ENDIF
                        IF (ABS(FDERIV) > TWO_EPSILON_EB) TMP_OTHER = TMP_OTHER - QEXTRA / FDERIV
                        IF (ABS(TMP_OTHER - TMP_F) / TMP_F < 1.E-4_EB .OR. ADCOUNT > 20) THEN
                           TMP_F = MAX(TMPMIN,MIN(TMPMAX,TMP_OTHER))
                           EXIT ADLOOP
                        ELSE
                           TMP_F = MAX(TMPMIN,MIN(TMPMAX,TMP_OTHER))
                           CYCLE ADLOOP
                        ENDIF
                     ENDDO ADLOOP
                     ONE_D%TMP_F = TMP_F
                     Q_CON_F_SUB(IW) = HTC*DTMP
                  ENDIF SOLID_PHASE_ONLY_IF

               CASE (THERMALLY_THICK_HT3D) ! thermally thick, continuous heat flux

                  IIG = BC%IIG
                  JJG = BC%JJG
                  KKG = BC%KKG
                  TMP_G = TMP_NEW(IIG,JJG,KKG)
                  ! Special case where the gas temperature is fixed by the user
                  IF (ASSUMED_GAS_TEMPERATURE > 0._EB) TMP_G = TMPA + &
                     EVALUATE_RAMP(T-T_BEGIN,I_RAMP_AGT)*(ASSUMED_GAS_TEMPERATURE-TMPA)
                  TMP_S = TMP_NEW(II,JJ,KK)
                  TMP_F = ONE_D%TMP_F
                  RDS = 0._EB
                  TMP_F_LOOP: DO ADCOUNT=1,3
                     SELECT CASE(ABS(IOR))
                        CASE( 1); RDN = MAX( RDS, RDX(II)/VSRVC_X(II,JJ,KK) )
                        CASE( 2); RDN = MAX( RDS, RDY(JJ)/VSRVC_Y(II,JJ,KK) )
                        CASE( 3); RDN = MAX( RDS, RDZ(KK)/VSRVC_Z(II,JJ,KK) )
                     END SELECT
                     DTMP = TMP_G - TMP_F
                     ONE_D%HEAT_TRANS_COEF = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SURF_INDEX,WALL_INDEX_IN=IW)
                     HTC = ONE_D%HEAT_TRANS_COEF
                     IF (RADIATION) THEN
                        TH_EST4 = 3._EB*ONE_D%EMISSIVITY*SIGMA*TMP_F**4
                        FO_EST3 = 4._EB*ONE_D%EMISSIVITY*SIGMA*TMP_F**3
                        TMP_F = ( ONE_D%Q_RAD_IN + TH_EST4 + HTC*TMP_G + 2._EB*K_S*RDN*TMP_S ) / &
                                (                   FO_EST3 + HTC       + 2._EB*K_S*RDN       )
                     ELSE
                        TMP_F = ( HTC*TMP_G + 2._EB*K_S*RDN*TMP_S ) / &
                                ( HTC       + 2._EB*K_S*RDN       )
                     ENDIF
                     IF (OB%MATL_INDEX>0) THEN
                        CALL GET_SOLID_RHOCBAR(RHOCBAR_S,TMP_S,OPT_MATL_INDEX=OB%MATL_INDEX)
                     ELSEIF (OB%MATL_SURF_INDEX>0) THEN
                        CALL GET_SOLID_RHOCBAR(RHOCBAR_S,TMP_S,OPT_SURF_INDEX=OB%MATL_SURF_INDEX,OPT_RHO_IN=RHO_GET)
                     ENDIF
                     SELECT CASE(SURFACE_HEAT_FLUX_MODEL)
                        CASE DEFAULT
                           RDS = 0._EB
                        CASE(1)
                           ! FDS Tech Guide (M.3), gives same length scale as 1D pyrolysis model
                           RDS = SQRT(RHOCBAR_S/K_S)
                        CASE(2)
                           ! experimental wall model, generally gives smaller length scale than 1D pyro model
                           KDTDN_S = ABS(K_S*2._EB*(TMP_F-TMP_S)*RDN)
                           RDS = 0.5_EB * ( KDTDN_S / (K_S/RHOCBAR_S)**3 / SUM(RHO_GET(1:MS%N_MATL)) )**ONTH
                     END SELECT
                  ENDDO TMP_F_LOOP
                  ONE_D%TMP_F = TMP_F
                  Q_CON_F_SUB(IW) = HTC*(TMP_G-TMP_F)

                  SELECT CASE(IOR)
                     CASE( 1); KDTDX(II,JJ,KK)   = K_S * 2._EB*(TMP_F-TMP_S)*RDN
                     CASE(-1); KDTDX(II-1,JJ,KK) = K_S * 2._EB*(TMP_S-TMP_F)*RDN
                     CASE( 2); KDTDY(II,JJ,KK)   = K_S * 2._EB*(TMP_F-TMP_S)*RDN
                     CASE(-2); KDTDY(II,JJ-1,KK) = K_S * 2._EB*(TMP_S-TMP_F)*RDN
                     CASE( 3); KDTDZ(II,JJ,KK)   = K_S * 2._EB*(TMP_F-TMP_S)*RDN
                     CASE(-3); KDTDZ(II,JJ,KK-1) = K_S * 2._EB*(TMP_S-TMP_F)*RDN
                  END SELECT

            END SELECT METHOD_OF_HEAT_TRANSFER

         ENDDO HT3D_WALL_LOOP

         ! Note: for 2D cylindrical KDTDX at X=0 remains zero after initialization

         DO K=1,KBAR
            DO J=1,JBAR
               DO I=1,IBAR
                  IC = CELL_INDEX(I,J,K)
                  IF (.NOT.SOLID(IC)) CYCLE
                  OB => OBSTRUCTION(OBST_INDEX_C(IC)); IF (.NOT.OB%HT3D) CYCLE
                  IF (OB%MATL_INDEX>0) THEN
                     CALL GET_SOLID_RHOCBAR(RHOCBAR_S,TMP_NEW(I,J,K),OPT_MATL_INDEX=OB%MATL_INDEX)
                  ELSEIF (OB%MATL_SURF_INDEX>0) THEN
                     MS => SURFACE(OB%MATL_SURF_INDEX)
                     RHO_GET(1:MS%N_MATL) = OB%RHO(I,J,K,1:MS%N_MATL)
                     CALL GET_SOLID_RHOCBAR(RHOCBAR_S,TMP_NEW(I,J,K),OPT_SURF_INDEX=OB%MATL_SURF_INDEX,OPT_RHO_IN=RHO_GET)
                  ENDIF
                  IF (TWO_D) THEN
                     VN_HT3D = MAX( VN_HT3D, 2._EB*K_S_MAX/RHOCBAR_S*( RDX(I)**2 + RDZ(K)**2 ) )
                  ELSE
                     VN_HT3D = MAX( VN_HT3D, 2._EB*K_S_MAX/RHOCBAR_S*( RDX(I)**2 + RDY(J)**2 + RDZ(K)**2 ) )
                  ENDIF

                  RAMP_FACTOR = 1._EB
                  IF (OB%RAMP_Q_INDEX>0) RAMP_FACTOR = EVALUATE_RAMP(T,OB%RAMP_Q_INDEX)

                  TMP_NEW(I,J,K) = TMP(I,J,K) + DT_SUB/RHOCBAR_S * ( (KDTDX(I,J,K)*R(I)-KDTDX(I-1,J,K)*R(I-1))*RDX(I)*RRN(I) + &
                                                                     (KDTDY(I,J,K)     -KDTDY(I,J-1,K)       )*RDY(J) + &
                                                                     (KDTDZ(I,J,K)     -KDTDZ(I,J,K-1)       )*RDZ(K) + &
                                                                     Q(I,J,K) + Q_DOT_PPP_S(I,J,K)*RAMP_FACTOR )

                  TMP_NEW(I,J,K) = MIN(TMPMAX,MAX(TMPMIN,TMP_NEW(I,J,K)))
               ENDDO
            ENDDO
         ENDDO

      ENDDO JACOBI_ITERATION_LOOP

      ! time step adjustment
      IF (DT_SUB*VN_HT3D < VN_MAX .OR. LOCK_TIME_STEP) THEN
         IS_STABLE_DT_SUB = .TRUE.
         TMP = TMP_NEW
         IF (SOLID_PYRO3D) CALL SOLID_PYROLYSIS_3D(DT_SUB,T_SUB)
         IF (SOLID_MT3D)   CALL SOLID_MASS_TRANSFER_3D(DT_SUB)
         ! integrate and store Q_CON_F for WALL cells
         QCONF_WALL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS
            WC => WALL(IW)
            IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY) CYCLE QCONF_WALL_LOOP
            SURF_INDEX = WC%SURF_INDEX
            SF => SURFACE(SURF_INDEX)
            ONE_D => BOUNDARY_ONE_D(WC%OD_INDEX)
            IF ( (SF%THERMAL_BC_INDEX==NET_FLUX_BC .AND. .NOT.SOLID_PHASE_ONLY) .OR. &
               SF%THERMAL_BC_INDEX==THERMALLY_THICK_HT3D ) THEN
               IF (T_SUB<TWO_EPSILON_EB) ONE_D%Q_CON_F = 0._EB
               ONE_D%Q_CON_F = ONE_D%Q_CON_F + Q_CON_F_SUB(IW) * DT_SUB/DT_BC_HT3D
            ENDIF
         ENDDO QCONF_WALL_LOOP
         T_SUB = T_SUB + DT_SUB
         IF (.NOT.LOCK_TIME_STEP) DT_SUB = MAX( DT_SUB, VN_MIN / MAX(VN_HT3D,TWO_EPSILON_EB) )
      ELSE
         DT_SUB = 0.5_EB*(VN_MIN+VN_MAX) / MAX(VN_HT3D,TWO_EPSILON_EB)
      ENDIF
      IF (DT_SUB < DT_SUB_MIN_HT3D .AND. (T+DT_SUB < (T_END-TWO_EPSILON_EB))) THEN
         WRITE(LU_ERR,'(A)') 'HT3D Instability: DT_SUB < 1e-9 s'
         STOP_STATUS = INSTABILITY_STOP
         RETURN
      ENDIF

   ENDDO TMP_UPDATE_LOOP

ENDDO SUBSTEP_LOOP

END SUBROUTINE SOLID_HEAT_TRANSFER_3D


SUBROUTINE SOLID_PYROLYSIS_3D(DT_SUB,T_SUB)
USE PHYSICAL_FUNCTIONS, ONLY: GET_SENSIBLE_ENTHALPY,GET_SOLID_RHOH
REAL(EB), INTENT(IN) :: DT_SUB,T_SUB
INTEGER :: N,NN,NS,I,J,K,IC,IIG,JJG,KKG,II2,JJ2,KK2,IOR,OBST_INDEX,II,JJ,KK,ITMP,ITER
REAL(EB) :: M_DOT_G_PPP_ADJUST(N_TRACKED_SPECIES),M_DOT_G_PPP_ACTUAL(N_TRACKED_SPECIES),M_DOT_S_PPP(MAX_MATERIALS),&
            RHO_IN(N_MATL),RHO_DOT_OUT(N_MATL),RHO_OUT(N_MATL),GEOM_FACTOR,TIME_FACTOR,VC,VC2,TMP_S,VSRVC_LOC,&
            TMP_F,Q_DOT_G_PPP,Q_DOT_O2_PPP,T_BOIL_EFF,H_NODE,T_NODE,H_S,C_S,RHOH,RHOH2,&
            M_DOT_P(MAX_LPC),Q_DOT_P(MAX_LPC),B_NUMBER,CP1,CP2,DENOM
LOGICAL :: OB2_FOUND
REAL(EB), PARAMETER :: SOLID_VOLUME_MERGE_THRESHOLD=0.1_EB, SOLID_VOLUME_CLIP_THRESHOLD=1.E-6_EB
TYPE(OBSTRUCTION_TYPE), POINTER :: OB=>NULL(),OB2=>NULL()
TYPE(SURFACE_TYPE), POINTER :: SF=>NULL(),MS=>NULL()
TYPE(WALL_TYPE), POINTER :: WC=>NULL()

TIME_FACTOR = DT_SUB/DT_BC_HT3D

INIT_IF: IF (T_SUB<TWO_EPSILON_EB) THEN
   OBST_LOOP_1: DO N=1,N_OBST
      OB => OBSTRUCTION(N)
      IF (OB%MT3D .OR. .NOT.OB%PYRO3D) CYCLE OBST_LOOP_1
      ! Set mass fluxes to 0
      K_LOOP_1: DO K=OB%K1+1,OB%K2
         J_LOOP_1: DO J=OB%J1+1,OB%J2
            I_LOOP_1: DO I=OB%I1+1,OB%I2
               IC = CELL_INDEX(I,J,K)
               IF (.NOT.SOLID(IC)) CYCLE I_LOOP_1
               IOR_SELECT: SELECT CASE(OB%PYRO3D_IOR)
                  CASE DEFAULT
                     IF (WALL_INDEX_HT3D(IC,OB%PYRO3D_IOR)>0) THEN
                        WC=>WALL(WALL_INDEX_HT3D(IC,OB%PYRO3D_IOR))
                        ONE_D=>BOUNDARY_ONE_D(WC%OD_INDEX)
                        SF=>SURFACE(WC%SURF_INDEX)
                        ONE_D%M_DOT_G_PP_ADJUST(1:N_TRACKED_SPECIES) = 0._EB
                        ONE_D%M_DOT_G_PP_ACTUAL(1:N_TRACKED_SPECIES) = 0._EB
                        ONE_D%M_DOT_S_PP(1:SF%N_MATL) = 0._EB
                     ENDIF
                  CASE(0)
                     IOR_LOOP: DO IOR=-3,3
                        IF (IOR==0) CYCLE IOR_LOOP
                        IF (WALL_INDEX_HT3D(IC,IOR)>0) THEN
                           WC=>WALL(WALL_INDEX_HT3D(IC,IOR))
                           ONE_D=>BOUNDARY_ONE_D(WC%OD_INDEX)
                           SF=>SURFACE(WC%SURF_INDEX)
                           ONE_D%M_DOT_G_PP_ADJUST(1:N_TRACKED_SPECIES) = 0._EB
                           ONE_D%M_DOT_G_PP_ACTUAL(1:N_TRACKED_SPECIES) = 0._EB
                           ONE_D%M_DOT_S_PP(1:SF%N_MATL) = 0._EB
                        ENDIF
                     ENDDO IOR_LOOP
               END SELECT IOR_SELECT
            ENDDO I_LOOP_1
         ENDDO J_LOOP_1
      ENDDO K_LOOP_1
   ENDDO OBST_LOOP_1
ENDIF INIT_IF

OBST_LOOP_2: DO N=1,N_OBST
   OB => OBSTRUCTION(N)
   IF (.NOT.OB%PYRO3D) CYCLE OBST_LOOP_2

   K_LOOP_2: DO K=OB%K1+1,OB%K2
      J_LOOP_2: DO J=OB%J1+1,OB%J2
         I_LOOP_2: DO I=OB%I1+1,OB%I2
            IC = CELL_INDEX(I,J,K)
            IF (.NOT.SOLID(IC)) CYCLE I_LOOP_2

            IF (.NOT.OB%MT3D) THEN
               WC=>WALL(WALL_INDEX_HT3D(IC,OB%PYRO3D_IOR))
               IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY) CYCLE I_LOOP_2
               SF=>SURFACE(WC%SURF_INDEX) ! PYROLYSIS SURFACE (ejection of pyrolyzate gas)
               BC=>BOUNDARY_COORD(WC%BC_INDEX)
               ONE_D=>BOUNDARY_ONE_D(WC%OD_INDEX)
               IIG = BC%IIG
               JJG = BC%JJG
               KKG = BC%KKG
               II  = BC%II
               JJ  = BC%JJ
               KK  = BC%KK
               IOR = BC%IOR
               SELECT CASE(ABS(IOR))
                  CASE(1); GEOM_FACTOR = DX(I)
                  CASE(2); GEOM_FACTOR = DY(J)
                  CASE(3); GEOM_FACTOR = DZ(K)
               END SELECT
            ELSE
               ! placeholders, should not matter for MT3D
               IIG = 1
               JJG = 1
               KKG = 1
               IOR = 1
               GEOM_FACTOR = 1._EB
            ENDIF

            ! only call pyrolysis for surface cells if material is a liquid

            IF (OB%PYRO3D_LIQUID) THEN
               IF (I/=II) CYCLE I_LOOP_2
               IF (J/=JJ) CYCLE I_LOOP_2
               IF (K/=KK) CYCLE I_LOOP_2
               ONE_D => BOUNDARY_ONE_D(WC%OD_INDEX)
               TMP_F = ONE_D%TMP_F
            ELSE
               TMP_F = 0._EB
            ENDIF

            MS=>SURFACE(OB%MATL_SURF_INDEX) ! MATERIAL SURFACE (supplies material properties)
            TMP_S = TMP(I,J,K)

            ! cell volume
            IF (TWO_D) THEN
               VC = DX(I)*DZ(K)
            ELSE
               VC = DX(I)*DY(J)*DZ(K)
            ENDIF

            ! update density
            RHO_IN(1:MS%N_MATL) = OB%RHO(I,J,K,1:MS%N_MATL)

            CALL PYROLYSIS(MS%N_MATL,MS%MATL_INDEX,OB%MATL_SURF_INDEX,IIG,JJG,KKG,TMP_S,TMP_F,IOR,&
                           RHO_DOT_OUT(1:MS%N_MATL),RHO_IN(1:MS%N_MATL),1._EB,DT_SUB,&
                           M_DOT_G_PPP_ADJUST,M_DOT_G_PPP_ACTUAL,M_DOT_S_PPP,Q_DOT_PPP_S(I,J,K),Q_DOT_G_PPP,Q_DOT_O2_PPP,&
                           M_DOT_P,Q_DOT_P,T_BOIL_EFF,B_NUMBER,1)

            IF (.NOT.OB%MT3D) ONE_D%B_NUMBER = B_NUMBER
            RHO_OUT(1:MS%N_MATL) = MAX( 0._EB , RHO_IN(1:MS%N_MATL) - DT_SUB*RHO_DOT_OUT(1:MS%N_MATL) )
            OB%RHO(I,J,K,1:MS%N_MATL) = OB%RHO(I,J,K,1:MS%N_MATL) + RHO_OUT(1:MS%N_MATL) - RHO_IN(1:MS%N_MATL)

            IF (OB%MT3D) THEN
               ! store mass production rate of gas species, adjusted for potential difference in heats of combustion
               DO NS=1,N_TRACKED_SPECIES
                  M_DOT_G_PPP_S(I,J,K,NS) = M_DOT_G_PPP_ADJUST(NS)
               ENDDO
            ELSE
               ! simple model (no transport): pyrolyzed mass is ejected via wall cell index WALL_INDEX_HT3D(IC,OB%PYRO3D_IOR)
               DO NS=1,N_TRACKED_SPECIES
                  ONE_D%M_DOT_G_PP_ADJUST(NS) = ONE_D%M_DOT_G_PP_ADJUST(NS) + M_DOT_G_PPP_ADJUST(NS)*GEOM_FACTOR*TIME_FACTOR
                  ONE_D%M_DOT_G_PP_ACTUAL(NS) = ONE_D%M_DOT_G_PP_ACTUAL(NS) + M_DOT_G_PPP_ACTUAL(NS)*GEOM_FACTOR*TIME_FACTOR
               ENDDO
               ! If the fuel or water massflux is non-zero, set the ignition time
               IF (ONE_D%T_IGN > T) THEN
                  IF (SUM(ONE_D%M_DOT_G_PP_ADJUST(1:N_TRACKED_SPECIES)) > 0._EB) ONE_D%T_IGN = T
               ENDIF
            ENDIF

            CONSUMABLE_IF: IF (OB%CONSUMABLE) THEN

               ! recompute solid volume ratio, VS/VC, for cell (I,J,K)
               VSRVC_LOC = 0._EB
               DO NN=1,MS%N_MATL
                  ML => MATERIAL(MS%MATL_INDEX(NN))
                  VSRVC_LOC = VSRVC_LOC + OB%RHO(I,J,K,NN)/ML%RHO_S
               ENDDO

               ! if local cell volume becomes too small, put the mass in the adjacent cell and remove local cell
               THRESHOLD_IF: IF (VSRVC_LOC<SOLID_VOLUME_MERGE_THRESHOLD) THEN
                  !print *,VSRVC_LOC,M_DOT_G_PPP_ADJUST,Q_DOT_PPP_S(I,J,K)
                  OB2_FOUND = .FALSE.
                  II2 = I
                  JJ2 = J
                  KK2 = K
                  ! first, see if cell exists in the minus IOR direction
                  SELECT CASE(IOR)
                     CASE ( 1); II2=I-1
                     CASE (-1); II2=I+1
                     CASE ( 2); JJ2=J-1
                     CASE (-2); JJ2=J+1
                     CASE ( 3); KK2=K-1
                     CASE (-3); KK2=K+1
                  END SELECT
                  OBST_INDEX = OBST_INDEX_C(CELL_INDEX(II2,JJ2,KK2))
                  OB2 => OBSTRUCTION(OBST_INDEX)
                  IF (OB2%PYRO3D) OB2_FOUND = .TRUE.
                  ! next, check surrounding cells
                  KK2_IF: IF (.NOT.OB2_FOUND) THEN
                     II2 = I
                     JJ2 = J
                     KK2_LOOP: DO KK2=K-1,K+1,2
                        OBST_INDEX = OBST_INDEX_C(CELL_INDEX(II2,JJ2,KK2))
                        OB2 => OBSTRUCTION(OBST_INDEX)
                        IF (OB2%PYRO3D) THEN
                           OB2_FOUND = .TRUE.
                           EXIT KK2_LOOP
                        ENDIF
                     ENDDO KK2_LOOP
                  ENDIF KK2_IF
                  JJ2_IF: IF (.NOT.OB2_FOUND) THEN
                     II2 = I
                     KK2 = K
                     JJ2_LOOP: DO JJ2=J-1,J+1,2
                        OBST_INDEX = OBST_INDEX_C(CELL_INDEX(II2,JJ2,KK2))
                        OB2 => OBSTRUCTION(OBST_INDEX)
                        IF (OB2%PYRO3D) THEN
                           OB2_FOUND = .TRUE.
                           EXIT JJ2_LOOP
                        ENDIF
                     ENDDO JJ2_LOOP
                  ENDIF JJ2_IF
                  II2_IF: IF (.NOT.OB2_FOUND) THEN
                     JJ2 = J
                     KK2 = K
                     II2_LOOP: DO II2=I-1,I+1,2
                        OBST_INDEX = OBST_INDEX_C(CELL_INDEX(II2,JJ2,KK2))
                        OB2 => OBSTRUCTION(OBST_INDEX)
                        IF (OB2%PYRO3D) THEN
                           OB2_FOUND = .TRUE.
                           EXIT II2_LOOP
                        ENDIF
                     ENDDO II2_LOOP
                  ENDIF II2_IF

                  OB2_IF: IF (OB2_FOUND) THEN
                     ! if an accepting cell exists, transfer energy and mass
                     IF (TWO_D) THEN
                        VC2 = DX(II2)*DZ(KK2)
                     ELSE
                        VC2 = DX(II2)*DY(JJ2)*DZ(KK2)
                     ENDIF
                     ! Get enthalpy
                     RHO_IN(1:MS%N_MATL) = OB%RHO(I,J,K,1:MS%N_MATL)
                     CALL GET_SOLID_RHOH(RHOH,TMP(I,J,K),OB%MATL_SURF_INDEX,RHO_IN)
                     RHO_IN(1:MS%N_MATL) = OB2%RHO(II2,JJ2,KK2,1:MS%N_MATL)
                     CALL GET_SOLID_RHOH(RHOH2,TMP(II2,JJ2,KK2),OB2%MATL_SURF_INDEX,RHO_IN)
                     H_NODE = (VC*RHOH+VC2*RHOH2)/VC2
                     ! Set guess for temperature search as mass weighted temperature
                     T_NODE = (VC*SUM(OB%RHO(I,J,K,1:MS%N_MATL))*TMP(I,J,K) + &
                               VC2*SUM(OB2%RHO(I,J,K,1:MS%N_MATL))*TMP(II2,JJ2,KK2)) / &
                              (VC*SUM(OB%RHO(I,J,K,1:MS%N_MATL))+VC2*SUM(OB2%RHO(I,J,K,1:MS%N_MATL)))
                     ! transfer mass of solid
                     OB2%RHO(II2,JJ2,KK2,1:MS%N_MATL) = OB2%RHO(II2,JJ2,KK2,1:MS%N_MATL) + OB%RHO(I,J,K,1:MS%N_MATL)*VC/VC2
                     ! compute new cell temperature
                     ITER = 0
                     T_SEARCH: DO
                        ITER = ITER + 1
                        C_S = 0._EB
                        H_S = 0._EB
                        CP1 = 0._EB
                        CP2 = 0._EB
                        ITMP = MIN(I_MAX_TEMP-1,INT(T_NODE))
                        T_S: DO NN=1,MS%N_MATL
                           IF (OB2%RHO(II2,JJ2,KK2,NN)<=0._EB) CYCLE T_S
                           ML  => MATERIAL(MS%MATL_INDEX(NN))
                           H_S = H_S + (ML%H(ITMP)+(T_NODE-REAL(ITMP,EB))*(ML%H(ITMP+1)-ML%H(ITMP)))*OB2%RHO(II2,JJ2,KK2,NN)
                           CP1 = CP1 + ML%H(ITMP)/REAL(ITMP,EB)*OB2%RHO(II2,JJ2,KK2,NN)
                           CP2 = CP2 + ML%H(ITMP+1)/REAL(ITMP+1,EB)*OB2%RHO(II2,JJ2,KK2,NN)
                        ENDDO T_S
                        C_S = H_S/T_NODE
                        DENOM = C_S+T_NODE*(CP2-CP1)
                        IF (ABS(DENOM) < TWO_EPSILON_EB) THEN
                           TMP(II2,JJ2,KK2) = T_NODE
                        ELSE
                           TMP(II2,JJ2,KK2) = T_NODE + (H_NODE - H_S)/DENOM
                        ENDIF
                        IF (ABS(TMP(II2,JJ2,KK2) - T_NODE) < 0.0001_EB) EXIT T_SEARCH
                        IF (ITER > 20) THEN
                           TMP(II2,JJ2,KK2) = 0.5_EB*(TMP(II2,JJ2,KK2)+T_NODE)
                           EXIT T_SEARCH
                        ENDIF
                        T_NODE = TMP(II2,JJ2,KK2)
                     ENDDO T_SEARCH

                     TMP(I,J,K) = TMP(IIG,JJG,KKG) ! replace solid cell tmp with nearest gas phase tmp
                     OB%RHO(I,J,K,1:MS%N_MATL) = 0._EB

                  ELSEIF (VSRVC_LOC<SOLID_VOLUME_CLIP_THRESHOLD) THEN OB2_IF
                     ! VS/VC is small, but there are no more cells to accept the mass, clip the mass
                     OB%RHO(I,J,K,1:MS%N_MATL) = 0._EB
                  ENDIF OB2_IF

               ENDIF THRESHOLD_IF
            ENDIF CONSUMABLE_IF

            OB%MASS = SUM(OB%RHO(I,J,K,1:MS%N_MATL))*VC
            IF (OB%MASS<TWO_EPSILON_EB) THEN
               OB%HT3D   = .FALSE.
               OB%PYRO3D = .FALSE.
               Q_DOT_PPP_S(I,J,K) = 0._EB
            ENDIF

         ENDDO I_LOOP_2
      ENDDO J_LOOP_2
   ENDDO K_LOOP_2
ENDDO OBST_LOOP_2

END SUBROUTINE SOLID_PYROLYSIS_3D


SUBROUTINE SOLID_MASS_TRANSFER_3D(DT_SUB)

USE MATH_FUNCTIONS, ONLY: INTERPOLATE1D_UNIFORM
REAL(EB), INTENT(IN) :: DT_SUB
INTEGER :: I,J,K,N,NN,NR,IC,II,JJ,KK,IOR,ICM,ICP
REAL(EB) :: D_Z_TEMP,D_Z_N(0:I_MAX_TEMP),D_F,R_D,VN_MT3D,RHO_ZZ_I,D_MAX,D_M,D_P,D_BAR,RHO_ZZ_F,RHO_ZZ_S,RDN
REAL(EB), POINTER, DIMENSION(:,:,:) :: D_DRHOZDX=>NULL(),D_DRHOZDY=>NULL(),D_DRHOZDZ=>NULL(),D_Z_P=>NULL(),RHO_ZZ_P=>NULL(),&
                                       VSRVC_X=>NULL(),VSRVC_Y=>NULL(),VSRVC_Z=>NULL(),VSRVC=>NULL()
LOGICAL :: CONT_MATL_PROP,IS_GAS_IN_SOLID(1:N_TRACKED_SPECIES),IS_GAS_FUEL(1:N_TRACKED_SPECIES)
TYPE(OBSTRUCTION_TYPE), POINTER :: OB=>NULL(),OBM=>NULL(),OBP=>NULL()
TYPE(SURFACE_TYPE), POINTER :: SF=>NULL()

! initialize work arrays

D_Z_P    =>WORK1; D_Z_P=0._EB
D_DRHOZDX=>WORK2; D_DRHOZDX=0._EB
D_DRHOZDY=>WORK3; D_DRHOZDY=0._EB
D_DRHOZDZ=>WORK4; D_DRHOZDZ=0._EB
RHO_ZZ_P =>WORK5; RHO_ZZ_P=0._EB

! CAUTION: work arrays computed in HT3D
VSRVC_X=>WORK6
VSRVC_Y=>WORK7
VSRVC_Z=>WORK8
VSRVC  =>WORK9

! determine which tracked species are to be transported (later move this to init)
IS_GAS_IN_SOLID = .FALSE.
DO NN=1,N_MATL
   ML => MATERIAL(NN)
   DO NR=1,ML%N_REACTIONS
      DO N=1,N_TRACKED_SPECIES
         IF (ABS(ML%NU_GAS(N,NR))>TWO_EPSILON_EB) IS_GAS_IN_SOLID(N) = .TRUE.
      ENDDO
   ENDDO
ENDDO
! which species are fuel gases
IS_GAS_FUEL = .FALSE.
DO NR=1,N_REACTIONS
   DO N=1,N_TRACKED_SPECIES
      IF (N==REACTION(NR)%FUEL_SMIX_INDEX) IS_GAS_FUEL(N) = .TRUE.
   ENDDO
ENDDO

! loop over all tracked gas species

D_MAX = 0._EB
VN_MT3D = 0._EB

SPECIES_LOOP: DO N=1,N_TRACKED_SPECIES

   IF (.NOT.IS_GAS_IN_SOLID(N)) CYCLE SPECIES_LOOP

   ! get gas phase diffusivity and density

   D_Z_N = D_Z(:,N)
   DO K=0,KBP1
      DO J=0,JBP1
         DO I=0,IBP1
            IC = CELL_INDEX(I,J,K);              IF (.NOT.SOLID(IC)) CYCLE
            OB => OBSTRUCTION(OBST_INDEX_C(IC)); IF (.NOT.OB%MT3D)   CYCLE
            CALL INTERPOLATE1D_UNIFORM(LBOUND(D_Z_N,1),D_Z_N,TMP(I,J,K),D_Z_TEMP)
            D_Z_P(I,J,K) = D_Z_TEMP
            ! if user specifies diffusivity on MATL line, over-ride defaults
            MATL_LOOP: DO NN=1,N_MATL
               ML => MATERIAL(NN)
               IF (ML%DIFFUSIVITY_GAS(N)>TWO_EPSILON_EB) D_Z_P(I,J,K) = ML%DIFFUSIVITY_GAS(N)
               EXIT MATL_LOOP
            ENDDO MATL_LOOP
            RHO_ZZ_P(I,J,K) = RHO_ZZ_G_S(I,J,K,N)
         ENDDO
      ENDDO
   ENDDO

   ! build mass flux vectors

   DO K=1,KBAR
      DO J=1,JBAR
         DO I=0,IBAR
            ICM = CELL_INDEX(I,J,K)
            ICP = CELL_INDEX(I+1,J,K)
            IF (.NOT.(SOLID(ICM).AND.SOLID(ICP))) CYCLE

            OBM => OBSTRUCTION(OBST_INDEX_C(ICM))
            OBP => OBSTRUCTION(OBST_INDEX_C(ICP))
            ! At present OBST_INDEX_C is not defined for ghost cells.
            ! This means that:
            !    1. continuous material properties will be assumed at a mesh boundary
            !    2. we assume that if either OBM%MT3D .OR. OBP%MT3D we should process the boundary
            IF (.NOT.(OBM%MT3D.OR.OBP%MT3D)) CYCLE

            D_M = D_Z_P(I,J,K)
            D_P = D_Z_P(I+1,J,K)

            IF (D_M<TWO_EPSILON_EB .OR. D_P<TWO_EPSILON_EB) THEN
               D_DRHOZDX(I,J,K) = 0._EB
               CYCLE
            ENDIF

            ! determine if we have continuous material properties
            CONT_MATL_PROP=.TRUE.
            IF (OBM%MATL_INDEX>0 .AND. OBP%MATL_INDEX>0 .AND. OBM%MATL_INDEX/=OBP%MATL_INDEX) THEN
               CONT_MATL_PROP=.FALSE.
            ELSEIF (OBM%MATL_SURF_INDEX>0 .AND. OBP%MATL_SURF_INDEX>0 .AND. OBM%MATL_SURF_INDEX/=OBP%MATL_SURF_INDEX) THEN
               CONT_MATL_PROP=.FALSE.
            ELSEIF (OBM%MATL_INDEX>0 .AND. OBP%MATL_SURF_INDEX>0) THEN
               CONT_MATL_PROP=.FALSE.
            ELSEIF (OBM%MATL_SURF_INDEX>0 .AND. OBP%MATL_INDEX>0) THEN
               CONT_MATL_PROP=.FALSE.
            ENDIF

            IF (CONT_MATL_PROP) THEN
               ! use linear average from inverse lever rule
               D_BAR = ( D_M*DX(I+1) + D_P*DX(I) )/( DX(I) + DX(I+1) )
               D_MAX = MAX(D_MAX,D_BAR)
               D_DRHOZDX(I,J,K) = D_BAR*(RHO_ZZ_P(I+1,J,K)-RHO_ZZ_P(I,J,K))*2._EB/(DX(I+1)*VSRVC_X(I+1,J,K)+DX(I)*VSRVC_X(I,J,K))
            ELSE
               ! for discontinuous material properties maintain continuity of flux, C0 continuity of composition
               ! (allow C1 discontinuity of composition due to jump in properties across interface)
               R_D = D_P/D_M * DX(I)/DX(I+1) * VSRVC_X(I,J,K)/VSRVC_X(I+1,J,K)
               RHO_ZZ_I = (RHO_ZZ_P(I,J,K) + R_D*RHO_ZZ_P(I+1,J,K))/(1._EB + R_D) ! interface concentration
               !! D_DRHOZDX(I,J,K) = D_P * (RHO_ZZ_P(I+1,J,K)-RHO_ZZ_I) * 2._EB/(DX(I+1)*VSRVC_X(I+1,J,K)) !! should be identical
               D_DRHOZDX(I,J,K) = D_M * (RHO_ZZ_I-RHO_ZZ_P(I,J,K)) * 2._EB/(DX(I)*VSRVC_X(I,J,K))
               D_MAX = MAX(D_MAX,MAX(D_M,D_P))
            ENDIF
         ENDDO
      ENDDO
   ENDDO
   TWO_D_IF: IF (.NOT.TWO_D) THEN
      DO K=1,KBAR
         DO J=0,JBAR
            DO I=1,IBAR
               ICM = CELL_INDEX(I,J,K)
               ICP = CELL_INDEX(I,J+1,K)
               IF (.NOT.(SOLID(ICM).AND.SOLID(ICP))) CYCLE
               OBM => OBSTRUCTION(OBST_INDEX_C(ICM))
               OBP => OBSTRUCTION(OBST_INDEX_C(ICP))
               IF (.NOT.(OBM%MT3D.OR.OBP%MT3D)) CYCLE

               D_M = D_Z_P(I,J,K)
               D_P = D_Z_P(I,J+1,K)

               IF (D_M<TWO_EPSILON_EB .OR. D_P<TWO_EPSILON_EB) THEN
                  D_DRHOZDY(I,J,K) = 0._EB
                  CYCLE
               ENDIF

               CONT_MATL_PROP=.TRUE.
               IF (OBM%MATL_INDEX>0 .AND. OBP%MATL_INDEX>0 .AND. OBM%MATL_INDEX/=OBP%MATL_INDEX) THEN
                  CONT_MATL_PROP=.FALSE.
               ELSEIF (OBM%MATL_SURF_INDEX>0 .AND. OBP%MATL_SURF_INDEX>0 .AND. OBM%MATL_SURF_INDEX/=OBP%MATL_SURF_INDEX) THEN
                  CONT_MATL_PROP=.FALSE.
               ELSEIF (OBM%MATL_INDEX>0 .AND. OBP%MATL_SURF_INDEX>0) THEN
                  CONT_MATL_PROP=.FALSE.
               ELSEIF (OBM%MATL_SURF_INDEX>0 .AND. OBP%MATL_INDEX>0) THEN
                  CONT_MATL_PROP=.FALSE.
               ENDIF

               IF (CONT_MATL_PROP) THEN
                  D_BAR = ( D_M*DY(J+1) + D_P*DY(J) )/( DY(J) + DY(J+1) )
                  D_MAX = MAX(D_MAX,D_BAR)
                  D_DRHOZDY(I,J,K)=D_BAR*(RHO_ZZ_P(I,J+1,K)-RHO_ZZ_P(I,J,K))*2._EB/(DY(J+1)*VSRVC_Y(I,J+1,K)+DY(J)*VSRVC_Y(I,J,K))
               ELSE
                  R_D = D_P/D_M * DY(J)/DY(J+1) * VSRVC_Y(I,J,K)/VSRVC_Y(I,J+1,K)
                  RHO_ZZ_I = (RHO_ZZ_P(I,J,K) + R_D*RHO_ZZ_P(I,J+1,K))/(1._EB + R_D)
                  D_DRHOZDY(I,J,K) = D_M * (RHO_ZZ_I-RHO_ZZ_P(I,J,K)) * 2._EB/(DY(J)*VSRVC_Y(I,J,K))
                  D_MAX = MAX(D_MAX,MAX(D_M,D_P))
               ENDIF
            ENDDO
         ENDDO
      ENDDO
   ELSE TWO_D_IF
      D_DRHOZDY(I,J,K) = 0._EB
   ENDIF TWO_D_IF
   DO K=0,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            ICM = CELL_INDEX(I,J,K)
            ICP = CELL_INDEX(I,J,K+1)
            IF (.NOT.(SOLID(ICM).AND.SOLID(ICP))) CYCLE
            OBM => OBSTRUCTION(OBST_INDEX_C(ICM))
            OBP => OBSTRUCTION(OBST_INDEX_C(ICP))
            IF (.NOT.(OBM%MT3D.OR.OBP%MT3D)) CYCLE

            D_M = D_Z_P(I,J,K)
            D_P = D_Z_P(I,J,K+1)

            IF (D_M<TWO_EPSILON_EB .OR. D_P<TWO_EPSILON_EB) THEN
               D_DRHOZDZ(I,J,K) = 0._EB
               CYCLE
            ENDIF

            CONT_MATL_PROP=.TRUE.
            IF (OBM%MATL_INDEX>0 .AND. OBP%MATL_INDEX>0 .AND. OBM%MATL_INDEX/=OBP%MATL_INDEX) THEN
               CONT_MATL_PROP=.FALSE.
            ELSEIF (OBM%MATL_SURF_INDEX>0 .AND. OBP%MATL_SURF_INDEX>0 .AND. OBM%MATL_SURF_INDEX/=OBP%MATL_SURF_INDEX) THEN
               CONT_MATL_PROP=.FALSE.
            ELSEIF (OBM%MATL_INDEX>0 .AND. OBP%MATL_SURF_INDEX>0) THEN
               CONT_MATL_PROP=.FALSE.
            ELSEIF (OBM%MATL_SURF_INDEX>0 .AND. OBP%MATL_INDEX>0) THEN
               CONT_MATL_PROP=.FALSE.
            ENDIF

            IF (CONT_MATL_PROP) THEN
               D_BAR = ( D_M*DZ(K+1) + D_P*DZ(K) )/( DZ(K) + DZ(K+1) )
               D_MAX = MAX(D_MAX,D_BAR)
               D_DRHOZDZ(I,J,K) = D_BAR*(RHO_ZZ_P(I,J,K+1)-RHO_ZZ_P(I,J,K))*2._EB/(DZ(K+1)*VSRVC_Z(I,J,K+1)+DZ(K)*VSRVC_Z(I,J,K))
            ELSE
               R_D = D_P/D_M * DZ(K)/DZ(K+1) * VSRVC_Z(I,J,K)/VSRVC_Z(I,J,K+1)
               RHO_ZZ_I = (RHO_ZZ_P(I,J,K) + R_D*RHO_ZZ_P(I,J,K+1))/(1._EB + R_D)
               D_DRHOZDZ(I,J,K) = D_M * (RHO_ZZ_I-RHO_ZZ_P(I,J,K)) * 2._EB/(DZ(K)*VSRVC_Z(I,J,K))
               D_MAX = MAX(D_MAX,MAX(D_M,D_P))
            ENDIF
         ENDDO
      ENDDO
   ENDDO

   ! build fluxes on boundaries of INTERNAL WALL CELLS

   MT3D_WALL_LOOP: DO IW=N_EXTERNAL_WALL_CELLS+1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS
      WC => WALL(IW)
      IF (WC%BOUNDARY_TYPE/=SOLID_BOUNDARY) CYCLE MT3D_WALL_LOOP

      BC => BOUNDARY_COORD(WC%BC_INDEX)
      ONE_D => BOUNDARY_ONE_D(WC%OD_INDEX)
      SF => SURFACE(WC%SURF_INDEX)
      II =  BC%II
      JJ =  BC%JJ
      KK =  BC%KK
      IOR = BC%IOR

      IC = CELL_INDEX(II,JJ,KK);           IF (.NOT.SOLID(IC)) CYCLE MT3D_WALL_LOOP
      OB => OBSTRUCTION(OBST_INDEX_C(IC)); IF (.NOT.OB%MT3D  ) CYCLE MT3D_WALL_LOOP

      CALL INTERPOLATE1D_UNIFORM(LBOUND(D_Z_N,1),D_Z_N,ONE_D%TMP_F,D_Z_TEMP)
      D_F = D_Z_TEMP
      ! if user specifies diffusivity on MATL line, over-ride defaults
      MATL_LOOP_2: DO NN=1,N_MATL
         ML => MATERIAL(NN)
         IF (ML%DIFFUSIVITY_GAS(N)>TWO_EPSILON_EB) D_F = ML%DIFFUSIVITY_GAS(N)
         EXIT MATL_LOOP_2
      ENDDO MATL_LOOP_2
      D_MAX = MAX(D_MAX,D_F)

      IF (SF%IMPERMEABLE) THEN
         RHO_ZZ_F = RHO_ZZ_P(II,JJ,KK)
      ELSE
         ! under construction:
         ! this scheme allows for oxygen diffusion into solid but forces fuel gases to flow out of solid
         IF (IS_GAS_FUEL(N)) THEN
            RHO_ZZ_F = 0._EB
         ELSE
            RHO_ZZ_F = ONE_D%RHO_F*ONE_D%ZZ_F(N)
         ENDIF
      ENDIF
      RHO_ZZ_S = RHO_ZZ_P(II,JJ,KK)

      SELECT CASE(ABS(IOR))
         CASE( 1); RDN = RDX(II)/VSRVC_X(II,JJ,KK)
         CASE( 2); RDN = RDY(JJ)/VSRVC_Y(II,JJ,KK)
         CASE( 3); RDN = RDZ(KK)/VSRVC_Z(II,JJ,KK)
      END SELECT

      ! compute mass flux at the surface

      SELECT CASE(IOR)
         CASE( 1); D_DRHOZDX(II,JJ,KK)   = D_F * 2._EB*(RHO_ZZ_F-RHO_ZZ_S)*RDN
         CASE(-1); D_DRHOZDX(II-1,JJ,KK) = D_F * 2._EB*(RHO_ZZ_S-RHO_ZZ_F)*RDN
         CASE( 2); D_DRHOZDY(II,JJ,KK)   = D_F * 2._EB*(RHO_ZZ_F-RHO_ZZ_S)*RDN
         CASE(-2); D_DRHOZDY(II,JJ-1,KK) = D_F * 2._EB*(RHO_ZZ_S-RHO_ZZ_F)*RDN
         CASE( 3); D_DRHOZDZ(II,JJ,KK)   = D_F * 2._EB*(RHO_ZZ_F-RHO_ZZ_S)*RDN
         CASE(-3); D_DRHOZDZ(II,JJ,KK-1) = D_F * 2._EB*(RHO_ZZ_S-RHO_ZZ_F)*RDN
      END SELECT

      SELECT CASE(IOR)
         CASE( 1); ONE_D%M_DOT_G_PP_ADJUST(N) = -D_DRHOZDX(II,JJ,KK)
         CASE(-1); ONE_D%M_DOT_G_PP_ADJUST(N) =  D_DRHOZDX(II-1,JJ,KK)
         CASE( 2); ONE_D%M_DOT_G_PP_ADJUST(N) = -D_DRHOZDY(II,JJ,KK)
         CASE(-2); ONE_D%M_DOT_G_PP_ADJUST(N) =  D_DRHOZDY(II,JJ-1,KK)
         CASE( 3); ONE_D%M_DOT_G_PP_ADJUST(N) = -D_DRHOZDZ(II,JJ,KK)
         CASE(-3); ONE_D%M_DOT_G_PP_ADJUST(N) =  D_DRHOZDZ(II,JJ,KK-1)
      END SELECT

      ! need to add ADJUST_BURN_RATE

      ONE_D%M_DOT_G_PP_ACTUAL(N) = ONE_D%M_DOT_G_PP_ADJUST(N)

      ! If the fuel or water massflux is non-zero, set the ignition time

      IF (ONE_D%T_IGN > T) THEN
         IF (ABS(ONE_D%M_DOT_G_PP_ADJUST(N)) > 0._EB) ONE_D%T_IGN = T
      ENDIF

   ENDDO MT3D_WALL_LOOP

   ! Note: for 2D cylindrical KDTDX at X=0 remains zero after initialization

   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IC = CELL_INDEX(I,J,K)
            IF (.NOT.SOLID(IC)) CYCLE
            OB => OBSTRUCTION(OBST_INDEX_C(IC)); IF (.NOT.OB%MT3D) CYCLE

            IF (TWO_D) THEN
               VN_MT3D = MAX( VN_MT3D, 2._EB*D_MAX*( RDX(I)**2 + RDZ(K)**2 ) )
            ELSE
               VN_MT3D = MAX( VN_MT3D, 2._EB*D_MAX*( RDX(I)**2 + RDY(J)**2 + RDZ(K)**2 ) )
            ENDIF

            RHO_ZZ_G_S(I,J,K,N) = RHO_ZZ_P(I,J,K) + DT_SUB * ( (D_DRHOZDX(I,J,K)*R(I)-D_DRHOZDX(I-1,J,K)*R(I-1))*RDX(I)*RRN(I) + &
                                                               (D_DRHOZDY(I,J,K)     -D_DRHOZDY(I,J-1,K)       )*RDY(J) + &
                                                               (D_DRHOZDZ(I,J,K)     -D_DRHOZDZ(I,J,K-1)       )*RDZ(K) + &
                                                               M_DOT_G_PPP_S(I,J,K,N) )

            RHO_ZZ_G_S(I,J,K,N) = MAX(0._EB,RHO_ZZ_G_S(I,J,K,N)) ! guarantee boundedness

         ENDDO
      ENDDO
   ENDDO

ENDDO SPECIES_LOOP

! update mass density

DO K=1,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         IC = CELL_INDEX(I,J,K)
         IF (.NOT.SOLID(IC)) CYCLE
         OB => OBSTRUCTION(OBST_INDEX_C(IC)); IF (.NOT.OB%MT3D) CYCLE

         RHO(I,J,K) = SUM(RHO_ZZ_G_S(I,J,K,1:N_TRACKED_SPECIES))
         IF (RHO(I,J,K)>TWO_EPSILON_EB) THEN
            ZZ(I,J,K,1:N_TRACKED_SPECIES) = RHO_ZZ_G_S(I,J,K,1:N_TRACKED_SPECIES)/RHO(I,J,K)
         ELSE
            ZZ(I,J,K,1:N_TRACKED_SPECIES) = 0._EB
            RHO(I,J,K) = TWO_EPSILON_EB
         ENDIF

      ENDDO
   ENDDO
ENDDO

END SUBROUTINE SOLID_MASS_TRANSFER_3D


SUBROUTINE CRANK_TEST_1(DIM)
! Initialize solid temperature profile for simple 1D verification test
! J. Crank, The Mathematics of Diffusion, 2nd Ed., Oxford Press, 1975, Sec 2.3.
INTEGER, INTENT(IN) :: DIM ! DIM=1,2,3 for x,y,z dimensions
INTEGER :: I,J,K,IC
REAL(EB), PARAMETER :: LL=1._EB, AA=100._EB, NN=2._EB, X_0=-.5_EB

DO K=1,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         IC = CELL_INDEX(I,J,K)
         IF (.NOT.SOLID(IC)) CYCLE
         SELECT CASE(DIM)
            CASE(1)
               TMP(I,J,K) = TMPA + AA * SIN(NN*PI*(XC(I)-X_0)/LL) ! TMPA = 293.15 K
            CASE(2)
               TMP(I,J,K) = TMPA + AA * SIN(NN*PI*(YC(J)-X_0)/LL)
            CASE(3)
               TMP(I,J,K) = TMPA + AA * SIN(NN*PI*(ZC(K)-X_0)/LL)
         END SELECT
      ENDDO
   ENDDO
ENDDO

END SUBROUTINE CRANK_TEST_1


END SUBROUTINE THERMAL_BC


!> \brief Calculate the term RHO_D_F=RHO*D at the wall.

SUBROUTINE DIFFUSIVITY_BC

INTEGER :: IW,ICF
REAL(EB) :: RHO_G,MU_G

IF (N_TRACKED_SPECIES==1) RETURN

! Loop over all WALL cells

WALL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS
   WC=>WALL(IW)
   IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY .OR. &
       WC%BOUNDARY_TYPE==OPEN_BOUNDARY .OR. &
       WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY) CYCLE WALL_LOOP
   ONE_D => BOUNDARY_ONE_D(WC%OD_INDEX)
   BC => BOUNDARY_COORD(WC%BC_INDEX)
   RHO_G = RHO(BC%IIG,BC%JJG,BC%KKG)
   MU_G = MU(BC%IIG,BC%JJG,BC%KKG)
   CALL CALCULATE_RHO_D_F
ENDDO WALL_LOOP

! Loop over all cut face cells

CFACE_LOOP: DO ICF=N_EXTERNAL_CFACE_CELLS+1,N_EXTERNAL_CFACE_CELLS+N_INTERNAL_CFACE_CELLS
   CFA => CFACE(ICF)
   ONE_D => BOUNDARY_ONE_D(CFA%OD_INDEX)
   BC => BOUNDARY_COORD(CFA%BC_INDEX)
   RHO_G = CFA%RHO_G
   MU_G  = CFA%MU_G
   CALL CALCULATE_RHO_D_F
ENDDO CFACE_LOOP

CONTAINS

SUBROUTINE CALCULATE_RHO_D_F

INTEGER :: N,ITMP,IIG,JJG,KKG

SELECT CASE(SIM_MODE)
   CASE DEFAULT
      DO N=1,N_TRACKED_SPECIES
         ONE_D%RHO_D_F(N) = MU_G*RSC*ONE_D%RHO_F/RHO_G
      ENDDO
   CASE (LES_MODE)
      ITMP = MIN(I_MAX_TEMP-1,NINT(ONE_D%TMP_F))
      IIG = BC%IIG
      JJG = BC%JJG
      KKG = BC%KKG
      DO N=1,N_TRACKED_SPECIES
         ONE_D%RHO_D_F(N) = ONE_D%RHO_F*( D_Z(ITMP,N) + (MU_G-MU_DNS(IIG,JJG,KKG))/RHO_G*RSC )
      ENDDO
   CASE (DNS_MODE)
      ITMP = MIN(I_MAX_TEMP-1,NINT(ONE_D%TMP_F))
      DO N=1,N_TRACKED_SPECIES
         ONE_D%RHO_D_F(N) = ONE_D%RHO_F*D_Z(ITMP,N)
      ENDDO
END SELECT

END SUBROUTINE CALCULATE_RHO_D_F

END SUBROUTINE DIFFUSIVITY_BC


!> \brief Compute the species mass fractions at the boundary, ZZ_F.
!>
!> \param T Current time (s)
!> \param DT Current time step (s)
!> \param NM Mesh number

SUBROUTINE SPECIES_BC(T,DT,NM)

USE PHYSICAL_FUNCTIONS, ONLY: GET_SPECIFIC_HEAT,SURFACE_DENSITY,GET_SENSIBLE_ENTHALPY
USE TRAN, ONLY: GET_IJK
USE OUTPUT_DATA, ONLY: M_DOT,Q_DOT
REAL(EB) :: RADIUS,AREA_SCALING,RVC,M_DOT_PPP_SINGLE,M_DOT_SINGLE,CP,MW_RATIO,H_G,&
            ZZ_GET(1:N_TRACKED_SPECIES),DENOM,M_GAS,TMP_G,RHO_G,ZZ_G(1:N_TRACKED_SPECIES)
REAL(EB), INTENT(IN) :: T,DT
INTEGER, INTENT(IN) :: NM
INTEGER :: II,JJ,KK,IIG,JJG,KKG,IW,IC,ICG,ICF,NS,IP,SPECIES_BC_INDEX,OBST_INDEX,IOR
REAL(EB), POINTER, DIMENSION(:,:) :: PBAR_P
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP
REAL(EB), POINTER, DIMENSION(:,:,:) :: UU,VV,WW,RHOP
REAL(EB) :: H_S_B

IF (PREDICTOR) THEN
   UU => US
   VV => VS
   WW => WS
   PBAR_P => PBAR_S
   ZZP => ZZS
   RHOP => RHOS
ELSE
   UU => U
   VV => V
   WW => W
   PBAR_P => PBAR
   ZZP => ZZ
   RHOP => RHO
ENDIF

! Add evaporating gases from solid particles to the mesh using a volumetric source term

PARTICLE_LOOP: DO IP=1,NLP

   LP  => LAGRANGIAN_PARTICLE(IP)
   LPC => LAGRANGIAN_PARTICLE_CLASS(LP%CLASS_INDEX)

   IF (.NOT.LPC%SOLID_PARTICLE) CYCLE PARTICLE_LOOP

   SF => SURFACE(LPC%SURF_INDEX)
   ONE_D => BOUNDARY_ONE_D(LP%OD_INDEX)
   BC  => BOUNDARY_COORD(LP%BC_INDEX)
   IIG = BC%IIG
   JJG = BC%JJG
   KKG = BC%KKG
   II  = IIG
   JJ  = JJG
   KK  = KKG
   IC  = CELL_INDEX(IIG,JJG,KKG)
   TMP_G = TMP(IIG,JJG,KKG)
   RHO_G = RHOP(IIG,JJG,KKG)
   ZZ_G(1:N_TRACKED_SPECIES) = ZZP(IIG,JJG,KKG,1:N_TRACKED_SPECIES)
   OBST_INDEX = 0

   CALL CALCULATE_ZZ_F

   ! Only do basic boundary conditions during the PREDICTOR stage of time step.

   IF (PREDICTOR) CYCLE PARTICLE_LOOP

   ! Get particle radius and surface area

   IF (SF%PYROLYSIS_MODEL==PYROLYSIS_PREDICTED) THEN
      RADIUS = SF%INNER_RADIUS + SUM(ONE_D%LAYER_THICKNESS(1:SF%N_LAYERS))
   ELSE
      RADIUS = SF%INNER_RADIUS + SF%THICKNESS
   ENDIF

   IF (ABS(RADIUS)<TWO_EPSILON_EB) CYCLE PARTICLE_LOOP

   AREA_SCALING = 1._EB
   IF (LPC%DRAG_LAW /= SCREEN_DRAG .AND. LPC%DRAG_LAW /= POROUS_DRAG) THEN
      SELECT CASE(SF%GEOMETRY)
         CASE(SURF_CARTESIAN)
            ONE_D%AREA = 2._EB*SF%LENGTH*SF%WIDTH
         CASE(SURF_CYLINDRICAL)
            ONE_D%AREA = TWOPI*RADIUS*SF%LENGTH
            IF (SF%THERMAL_BC_INDEX == THERMALLY_THICK) AREA_SCALING = (SF%INNER_RADIUS+SF%THICKNESS)/RADIUS
         CASE(SURF_SPHERICAL)
            ONE_D%AREA = 4._EB*PI*RADIUS**2
            IF (SF%THERMAL_BC_INDEX == THERMALLY_THICK) AREA_SCALING = ((SF%INNER_RADIUS+SF%THICKNESS)/RADIUS)**2
     END SELECT
   ELSE
      SELECT CASE(SF%GEOMETRY)
         CASE(SURF_CARTESIAN)
            ONE_D%AREA = 2._EB*LPC%LENGTH**2
         CASE(SURF_CYLINDRICAL)
            ONE_D%AREA = TWOPI*RADIUS*LPC%LENGTH
            IF (SF%THERMAL_BC_INDEX == THERMALLY_THICK) AREA_SCALING = (SF%INNER_RADIUS+SF%THICKNESS)/RADIUS
         CASE(SURF_SPHERICAL)
            ONE_D%AREA = 4._EB*PI*RADIUS**2
            IF (SF%THERMAL_BC_INDEX == THERMALLY_THICK) AREA_SCALING = ((SF%INNER_RADIUS+SF%THICKNESS)/RADIUS)**2
     END SELECT
   ENDIF

   ! In PYROLYSIS, all the mass fluxes are normalized by a virtual area based on the INITIAL radius.
   ! Here, correct the mass flux using the CURRENT radius.

   IF (CALL_HT_1D) THEN
      ONE_D%M_DOT_G_PP_ADJUST(1:N_TRACKED_SPECIES) = ONE_D%M_DOT_G_PP_ADJUST(1:N_TRACKED_SPECIES)*AREA_SCALING
      ONE_D%M_DOT_G_PP_ACTUAL(1:N_TRACKED_SPECIES) = ONE_D%M_DOT_G_PP_ACTUAL(1:N_TRACKED_SPECIES)*AREA_SCALING
      ONE_D%M_DOT_S_PP(1:SF%N_MATL)                = ONE_D%M_DOT_S_PP(1:SF%N_MATL)               *AREA_SCALING
      ONE_D%Q_DOT_G_PP                             = ONE_D%Q_DOT_G_PP                            *AREA_SCALING
      ONE_D%Q_DOT_O2_PP                            = ONE_D%Q_DOT_O2_PP                           *AREA_SCALING
   ENDIF

   ! Add evaporated particle species to gas phase and compute resulting contribution to the divergence

   RVC = RDX(IIG)*RRN(IIG)*RDY(JJG)*RDZ(KKG)
   M_GAS = RHO_G/RVC
   DO NS=1,N_TRACKED_SPECIES
      IF (ABS(ONE_D%M_DOT_G_PP_ADJUST(NS))<=TWO_EPSILON_EB) CYCLE
      MW_RATIO = SPECIES_MIXTURE(NS)%RCON/RSUM(BC%IIG,BC%JJG,BC%KKG)
      M_DOT_SINGLE = LP%PWT*ONE_D%M_DOT_G_PP_ADJUST(NS)*ONE_D%AREA
      D_SOURCE(IIG,JJG,KKG) = D_SOURCE(IIG,JJG,KKG) + M_DOT_SINGLE*(MW_RATIO/M_GAS)
      M_DOT_PPP(IIG,JJG,KKG,NS) = M_DOT_PPP(IIG,JJG,KKG,NS) + M_DOT_SINGLE*RVC
      ZZ_GET = 0._EB
      ZZ_GET(NS) = 1._EB
      CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S_B,ONE_D%TMP_F)
      Q_DOT(3,NM) = Q_DOT(3,NM) + ONE_D%M_DOT_G_PP_ADJUST(NS)*ONE_D%AREA*H_S_B*LP%PWT    ! Q_CONV
   ENDDO

   ! Calculate term in divergence that accounts for change in enthalpy between gas generated by pyrolysis and surrounding gas

   ZZ_GET(1:N_TRACKED_SPECIES) = ZZ_G(1:N_TRACKED_SPECIES)
   CALL GET_SPECIFIC_HEAT(ZZ_GET,CP,TMP_G)
   H_G = CP*TMP_G*M_GAS

   D_SOURCE(IIG,JJG,KKG) = D_SOURCE(IIG,JJG,KKG) - ONE_D%Q_DOT_G_PP*ONE_D%AREA/H_G * LP%PWT

   ! Calculate contribution to divergence term due to convective heat transfer from particle

   D_SOURCE(IIG,JJG,KKG) = D_SOURCE(IIG,JJG,KKG) - ONE_D%Q_CON_F*ONE_D%AREA/H_G * LP%PWT

   ! Add energy losses and gains to overall energy budget array

   Q_DOT(7,NM) = Q_DOT(7,NM) - (ONE_D%Q_CON_F + ONE_D%Q_RAD_IN - ONE_D%Q_RAD_OUT)*ONE_D%AREA*LP%PWT      ! Q_PART
   Q_DOT(2,NM) = Q_DOT(2,NM) + (ONE_D%Q_RAD_IN-ONE_D%Q_RAD_OUT)*ONE_D%AREA*LP%PWT                        ! Q_RADI

   ! Calculate the mass flux of fuel gas from particles

   IF (CORRECTOR) THEN
      DO NS=1,N_TRACKED_SPECIES
         M_DOT(NS,NM) = M_DOT(NS,NM) + ONE_D%M_DOT_G_PP_ACTUAL(NS)*ONE_D%AREA*LP%PWT
      ENDDO
   ENDIF

   ! Calculate particle mass

   CALC_LP_MASS: IF (SF%THERMAL_BC_INDEX==THERMALLY_THICK) THEN
      SELECT CASE (SF%GEOMETRY)
         CASE (SURF_CARTESIAN)
            IF (LPC%DRAG_LAW==SCREEN_DRAG .OR. LPC%DRAG_LAW==POROUS_DRAG) THEN
               LP%MASS = 2._EB*LPC%LENGTH**2*SF%THICKNESS*SURFACE_DENSITY(NM,1,LAGRANGIAN_PARTICLE_INDEX=IP)
            ELSE
               LP%MASS = 2._EB*SF%LENGTH*SF%WIDTH*SF%THICKNESS*SURFACE_DENSITY(NM,1,LAGRANGIAN_PARTICLE_INDEX=IP)
            ENDIF
          CASE (SURF_CYLINDRICAL)
            IF (LPC%DRAG_LAW==SCREEN_DRAG .OR. LPC%DRAG_LAW==POROUS_DRAG) THEN
               LP%MASS = LPC%LENGTH*PI*(SF%INNER_RADIUS+SF%THICKNESS)**2*SURFACE_DENSITY(NM,1,LAGRANGIAN_PARTICLE_INDEX=IP)
            ELSE
               LP%MASS = SF%LENGTH*PI*(SF%INNER_RADIUS+SF%THICKNESS)**2*SURFACE_DENSITY(NM,1,LAGRANGIAN_PARTICLE_INDEX=IP)
            ENDIF
         CASE (SURF_SPHERICAL)
            LP%MASS = FOTHPI*(SF%INNER_RADIUS+SF%THICKNESS)**3*SURFACE_DENSITY(NM,1,LAGRANGIAN_PARTICLE_INDEX=IP)
      END SELECT
   ENDIF CALC_LP_MASS

ENDDO PARTICLE_LOOP

! Loop through the wall cells, apply mass boundary conditions

WALL_CELL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS

   WC => WALL(IW)

   IF (WC%BOUNDARY_TYPE==OPEN_BOUNDARY)         CYCLE WALL_CELL_LOOP
   IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY)         CYCLE WALL_CELL_LOOP
   IF (WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY) CYCLE WALL_CELL_LOOP

   ONE_D => BOUNDARY_ONE_D(WC%OD_INDEX)
   BP => BOUNDARY_PROPS(WC%BP_INDEX)
   BC => BOUNDARY_COORD(WC%BC_INDEX)
   SF => SURFACE(WC%SURF_INDEX)
   II  = BC%II
   JJ  = BC%JJ
   KK  = BC%KK
   IC  = CELL_INDEX(II,JJ,KK)
   IIG = BC%IIG
   JJG = BC%JJG
   KKG = BC%KKG
   ICG = CELL_INDEX(IIG,JJG,KKG)
   TMP_G = TMP(IIG,JJG,KKG)
   RHO_G = RHOP(IIG,JJG,KKG)
   ZZ_G(:) = ZZP(IIG,JJG,KKG,:)
   OBST_INDEX = WC%OBST_INDEX

   CALL CALCULATE_ZZ_F(WALL_INDEX=IW)

   ! Only set species mass fraction in the ghost cell if it is not solid

   IF (IW<=N_EXTERNAL_WALL_CELLS .AND. .NOT.SOLID(IC) .AND. .NOT.SOLID(ICG)) &
       ZZP(II,JJ,KK,1:N_TRACKED_SPECIES) = 2._EB*ONE_D%ZZ_F(1:N_TRACKED_SPECIES) - ZZ_G(1:N_TRACKED_SPECIES)

ENDDO WALL_CELL_LOOP

! Loop through the cut face cells, apply mass boundary conditions

CFACE_LOOP: DO ICF=N_EXTERNAL_CFACE_CELLS+1,N_EXTERNAL_CFACE_CELLS+N_INTERNAL_CFACE_CELLS

   CFA => CFACE(ICF)
   ONE_D => BOUNDARY_ONE_D(CFA%OD_INDEX)
   BP => BOUNDARY_PROPS(CFA%BP_INDEX)
   BC => BOUNDARY_COORD(CFA%BC_INDEX)
   SF => SURFACE(CFA%SURF_INDEX)
   KK  = BC%KK
   IC  = 0
   ICG = 0
   TMP_G = CFA%TMP_G
   RHO_G = CFA%RHO_G
   ZZ_G  = CFA%ZZ_G
   OBST_INDEX = 0
   CALL CALCULATE_ZZ_F(CFACE_INDEX=ICF)

ENDDO CFACE_LOOP

CONTAINS

SUBROUTINE CALCULATE_ZZ_F(WALL_INDEX,CFACE_INDEX)

USE HVAC_ROUTINES, ONLY : DUCT_MF
USE PHYSICAL_FUNCTIONS, ONLY: GET_SPECIFIC_GAS_CONSTANT, GET_REALIZABLE_MF, GET_AVERAGE_SPECIFIC_HEAT
USE MATH_FUNCTIONS, ONLY : EVALUATE_RAMP, BOX_MULLER, INTERPOLATE1D_UNIFORM
REAL(EB) :: UN,DD,MFT,TSI,RSUM_F,MPUA_SUM,RHO_F_PREVIOUS,RN1,RN2,TWOMFT,Q_NEW
INTEGER :: N,ITER,IIO,JJO,KKO,OTHER_MESH_OBST_INDEX,LL
INTEGER, INTENT(IN), OPTIONAL :: WALL_INDEX,CFACE_INDEX
TYPE(RAMPS_TYPE), POINTER :: RP=>NULL()

! Special cases for N_TRACKED_SPECIES==1

IF (N_TRACKED_SPECIES==1) THEN

   IF ( ONE_D%NODE_INDEX < 0 .AND. .NOT.SF%SPECIES_BC_INDEX==SPECIFIED_MASS_FLUX ) THEN
      ONE_D%ZZ_F(1) = 1._EB
      RETURN
   ENDIF

   IF ( SF%SPECIES_BC_INDEX==SPECIFIED_MASS_FLUX .AND. ABS(SF%MASS_FLUX(1))<=TWO_EPSILON_EB ) THEN
      ONE_D%ZZ_F(1) = 1._EB
      RETURN
   ENDIF

ENDIF

! Check if suppression by water is to be applied and sum water on surface

IF (CORRECTOR .AND. SF%E_COEFFICIENT>0._EB .AND. I_WATER>0 .AND. (PRESENT(WALL_INDEX).OR.PRESENT(CFACE_INDEX))) THEN
   IF (SPECIES_MIXTURE(I_WATER)%EVAPORATING) THEN
      MPUA_SUM = 0._EB
      DO N=1,N_LAGRANGIAN_CLASSES
         LPC=>LAGRANGIAN_PARTICLE_CLASS(N)
         IF (LPC%Z_INDEX==I_WATER) MPUA_SUM = MPUA_SUM + BP%LP_MPUA(LPC%ARRAY_INDEX)
      ENDDO
      BP%K_SUPPRESSION = BP%K_SUPPRESSION + SF%E_COEFFICIENT*MPUA_SUM*DT
   ENDIF
ENDIF

! Get general SPECIES_BC_INDEX

SPECIES_BC_INDEX = SF%SPECIES_BC_INDEX

! Get SPECIES_BC_INDEX and adjust for HVAC

IF (ONE_D%NODE_INDEX > 0) THEN
   IF (-DUCTNODE(ONE_D%NODE_INDEX)%DIR(1)*DUCT_MF(DUCTNODE(ONE_D%NODE_INDEX)%DUCT_INDEX(1))>=0._EB) THEN
      SPECIES_BC_INDEX = SPECIFIED_MASS_FRACTION
   ELSE
      SPECIES_BC_INDEX = SPECIFIED_MASS_FLUX
   ENDIF
ENDIF

! Apply the different species boundary conditions to non-thermally thick solids

METHOD_OF_MASS_TRANSFER: SELECT CASE(SPECIES_BC_INDEX)

   CASE (INFLOW_OUTFLOW_MASS_FLUX) METHOD_OF_MASS_TRANSFER

      ! OPEN boundary species BC is done in THERMAL_BC under INFLOW_OUTFLOW

   CASE (NO_MASS_FLUX) METHOD_OF_MASS_TRANSFER

      ONE_D%ZZ_F(1:N_TRACKED_SPECIES) = ZZ_G(1:N_TRACKED_SPECIES)

   CASE (SPECIFIED_MASS_FRACTION) METHOD_OF_MASS_TRANSFER

      IF (ABS(ONE_D%T_IGN-T_BEGIN)<SPACING(ONE_D%T_IGN) .AND. ANY(SF%RAMP_INDEX>=1)) THEN
         IF (PREDICTOR) TSI = T + DT
         IF (CORRECTOR) TSI = T
      ELSE
         IF (PREDICTOR) TSI = T + DT - ONE_D%T_IGN
         IF (CORRECTOR) TSI = T      - ONE_D%T_IGN
      ENDIF

      IF (ONE_D%U_NORMAL_S<0._EB) THEN  ! If there is a non-zero velocity into the domain, assign appropriate species
                                        ! mass fractions to the face
         DO N=2,N_TRACKED_SPECIES
            ZZ_GET(N) = SPECIES_MIXTURE(N)%ZZ0 + EVALUATE_RAMP(TSI,SF%RAMP_INDEX(N),TAU=SF%TAU(N))* &
                           (SF%MASS_FRACTION(N)-SPECIES_MIXTURE(N)%ZZ0)
         ENDDO
         ZZ_GET(1) = 1._EB-SUM(ZZ_GET(2:N_TRACKED_SPECIES))
         CALL GET_REALIZABLE_MF(ZZ_GET)
         ONE_D%ZZ_F = ZZ_GET
      ELSE
         ONE_D%ZZ_F(1:N_TRACKED_SPECIES) = ZZ_G(1:N_TRACKED_SPECIES)
      ENDIF

      IF (PERIODIC_TEST==12 .AND. (TRIM(SF%ID)=='inlet')) THEN
         ONE_D%ZZ_F(2) = 1._EB
         ONE_D%ZZ_F(1) = 0._EB
      ENDIF
      IF (PERIODIC_TEST==13 .AND. (TRIM(SF%ID)=='inlet')) THEN
         ONE_D%ZZ_F(2) = 0.5_EB*(1._EB + COS(4._EB*PI*XC(BC%II)))
         ONE_D%ZZ_F(1) = 1._EB - ONE_D%ZZ_F(2)
      ENDIF

      ! reconstruct species mass flux at the surface for output (some terms are lagged)

      IIG = BC%IIG
      JJG = BC%JJG
      KKG = BC%KKG
      IOR = BC%IOR
      SELECT CASE(IOR)
         CASE( 1); UN = UU(IIG-1,JJG,KKG)
         CASE(-1); UN = UU(IIG,JJG,KKG)
         CASE( 2); UN = VV(IIG,JJG-1,KKG)
         CASE(-2); UN = VV(IIG,JJG,KKG)
         CASE( 3); UN = WW(IIG,JJG,KKG-1)
         CASE(-3); UN = WW(IIG,JJG,KKG)
      END SELECT
      DO N=1,N_TRACKED_SPECIES
         ONE_D%M_DOT_G_PP_ADJUST(N) = SIGN(1._EB,REAL(IOR,EB))*( ONE_D%RHO_F*ONE_D%ZZ_F(N)*UN - ONE_D%RHO_D_DZDN_F(N) )
         ONE_D%M_DOT_G_PP_ACTUAL(N) = ONE_D%M_DOT_G_PP_ADJUST(N)
      ENDDO

   CASE (SPECIFIED_MASS_FLUX) METHOD_OF_MASS_TRANSFER
      ! Calculate smoothed incident heat flux if cone scaling is applied
      IF (SF%REFERENCE_HEAT_FLUX > 0._EB) THEN
         TSI = MIN(T-T_BEGIN+DT, SF%REFERENCE_HEAT_FLUX_TIME_INTERVAL+DT)
         ONE_D%Q_IN_SMOOTH = (ONE_D%Q_IN_SMOOTH *(TSI-DT) + DT*(ONE_D%Q_CON_F+ONE_D%Q_RAD_IN))/TSI
      ENDIF

      ! If the current time is before the "activation" time, T_IGN, apply simple BCs and get out

      IF (T < ONE_D%T_IGN .OR. ONE_D%T_IGN+ONE_D%BURN_DURATION<T .OR. INITIALIZATION_PHASE) THEN
         ONE_D%ZZ_F(1:N_TRACKED_SPECIES) = ZZ_G(1:N_TRACKED_SPECIES)
         IF (PREDICTOR) ONE_D%U_NORMAL_S = 0._EB
         IF (CORRECTOR) ONE_D%U_NORMAL  = 0._EB
         ONE_D%M_DOT_G_PP_ADJUST(1:N_TRACKED_SPECIES) = 0._EB
         ONE_D%M_DOT_G_PP_ACTUAL(1:N_TRACKED_SPECIES) = 0._EB
         ONE_D%M_DOT_S_PP(1:SF%N_MATL) = 0._EB
         ONE_D%M_DOT_PART_ACTUAL = 0._EB
         RETURN
      ENDIF

      ! Zero out the running counter of Mass Flux Total (MFT)

      MFT = 0._EB

      ! If the user has specified the burning rate, evaluate the ramp and other related parameters

      SUM_MASSFLUX_LOOP: DO N=1,N_TRACKED_SPECIES
         IF (ABS(SF%MASS_FLUX(N)) > TWO_EPSILON_EB) THEN  ! Use user-specified ramp-up of mass flux
            IF (ABS(ONE_D%T_IGN-T_BEGIN) < SPACING(ONE_D%T_IGN) .AND. SF%RAMP_INDEX(N)>=1) THEN
               IF (PREDICTOR) TSI = T + DT
               IF (CORRECTOR) TSI = T
            ELSE
               IF (PREDICTOR) TSI = T + DT - ONE_D%T_IGN
               IF (CORRECTOR) TSI = T      - ONE_D%T_IGN
            ENDIF
            ! Check for cone data burning rate and compute scaled rate and time
            IF (SF%REFERENCE_HEAT_FLUX > 0._EB .AND. N==REACTION(1)%FUEL_SMIX_INDEX) THEN
               IF (PREDICTOR) THEN
                  RP => RAMPS(SF%RAMP_INDEX(N))
                  
                  IF (SF%EMISSIVITY > 0._EB) THEN
                     ONE_D%T_SCALE = ONE_D%T_SCALE + DT * MAX(0._EB,ONE_D%Q_IN_SMOOTH) / (SF%REFERENCE_HEAT_FLUX * SF%EMISSIVITY)
                  ELSE
                     ONE_D%T_SCALE = ONE_D%T_SCALE + DT * MAX(0._EB,ONE_D%Q_IN_SMOOTH) / (SF%REFERENCE_HEAT_FLUX)
                  ENDIF
                  CALL INTERPOLATE1D_UNIFORM(1,RP%INTERPOLATED_DATA(1:RP%NUMBER_INTERPOLATION_POINTS),ONE_D%T_SCALE*RP%RDT,Q_NEW)
                  ONE_D%M_DOT_G_PP_ACTUAL(N) = (Q_NEW-ONE_D%Q_SCALE)/DT*SF%MASS_FLUX(N)
                  ONE_D%Q_SCALE = Q_NEW
               ENDIF
            ELSE
               ONE_D%M_DOT_G_PP_ACTUAL(N) = EVALUATE_RAMP(TSI,SF%RAMP_INDEX(N),TAU=SF%TAU(N))*SF%MASS_FLUX(N)
            ENDIF
            ONE_D%M_DOT_G_PP_ADJUST(N) = SF%ADJUST_BURN_RATE(N)*ONE_D%M_DOT_G_PP_ACTUAL(N)*ONE_D%AREA_ADJUST
         ENDIF
         MFT = MFT + ONE_D%M_DOT_G_PP_ADJUST(N)
      ENDDO SUM_MASSFLUX_LOOP

      ! Apply user-specified mass flux variation

      IF (SF%MASS_FLUX_VAR > TWO_EPSILON_EB) THEN
         ! generate pairs of standard Gaussian random variables
         CALL BOX_MULLER(RN1,RN2)
         TWOMFT = 2._EB*MFT
         MFT = MFT*(1._EB + RN1*SF%MASS_FLUX_VAR)
         MFT = MAX(0._EB,MIN(TWOMFT,MFT))
      ENDIF

      ! Apply water suppression coefficient (EW) at a WALL cell

      IF (PRESENT(WALL_INDEX) .OR. PRESENT(CFACE_INDEX)) THEN
         IF (BP%K_SUPPRESSION>TWO_EPSILON_EB) THEN
            ONE_D%M_DOT_G_PP_ADJUST(1:N_TRACKED_SPECIES) = ONE_D%M_DOT_G_PP_ADJUST(1:N_TRACKED_SPECIES)*EXP(-BP%K_SUPPRESSION)
            ONE_D%M_DOT_G_PP_ACTUAL(1:N_TRACKED_SPECIES) = ONE_D%M_DOT_G_PP_ACTUAL(1:N_TRACKED_SPECIES)*EXP(-BP%K_SUPPRESSION)
         ENDIF
      ENDIF

      ! If processing a 1-D, thermally-thick WALL cell, reduce the mass of the OBSTruction (OB%MASS) to which the WALL cell is
      ! attached. If the WALL cell is at the exterior of the current MESH, and the OBSTstruction to which it is attached
      ! lives in a neighboring MESH, store the mass to be subtracted and the index of the OBSTstruction in a 1-D array
      ! called MESHES(NM)%OMESH(NOM)%REAL_SEND_PKG8. This array will be sent to the neighboring MESH (NOM) the next time a
      ! MESH_EXCHANGE is done in main.f90.

      CONSUME_MASS: IF (PRESENT(WALL_INDEX) .AND. CORRECTOR .AND. SF%THERMAL_BC_INDEX/=THERMALLY_THICK_HT3D) THEN
         OTHER_MESH_OBST_INDEX = 0
         IF (WALL_INDEX<=N_EXTERNAL_WALL_CELLS) THEN
            EWC => EXTERNAL_WALL(WALL_INDEX)
            IF (EWC%NOM>0) THEN
               IIO = EWC%IIO_MIN
               JJO = EWC%JJO_MIN
               KKO = EWC%KKO_MIN
               OTHER_MESH_OBST_INDEX = MESHES(EWC%NOM)%OBST_INDEX_C(MESHES(EWC%NOM)%CELL_INDEX(IIO,JJO,KKO))
            ENDIF
         ENDIF
         IF (OTHER_MESH_OBST_INDEX>0) THEN
            IF (OBST_INDEX>0) OBSTRUCTION(OBST_INDEX)%MASS = MESHES(EWC%NOM)%OBSTRUCTION(OTHER_MESH_OBST_INDEX)%MASS
            IF (MESHES(EWC%NOM)%OBSTRUCTION(OTHER_MESH_OBST_INDEX)%CONSUMABLE) THEN
               OMESH(EWC%NOM)%N_EXTERNAL_OBST = OMESH(EWC%NOM)%N_EXTERNAL_OBST + 1
               LL = 2*OMESH(EWC%NOM)%N_EXTERNAL_OBST
               OMESH(EWC%NOM)%REAL_SEND_PKG8(LL-1) = REAL(OTHER_MESH_OBST_INDEX,EB)
               OMESH(EWC%NOM)%REAL_SEND_PKG8(LL)   = &
                  (ONE_D%M_DOT_PART_ACTUAL+SUM(ONE_D%M_DOT_G_PP_ACTUAL(1:N_TRACKED_SPECIES)))*DT*ONE_D%AREA
            ENDIF
         ELSE
            IF (OBST_INDEX>0) OBSTRUCTION(OBST_INDEX)%MASS = OBSTRUCTION(OBST_INDEX)%MASS - &
               (ONE_D%M_DOT_PART_ACTUAL+SUM(ONE_D%M_DOT_G_PP_ACTUAL(1:N_TRACKED_SPECIES)))*DT*ONE_D%AREA
         ENDIF
      ENDIF CONSUME_MASS

      ! Compute the cell face value of the species mass fraction to get the right mass flux

      IF (N_TRACKED_SPECIES==1) THEN  ! there is just the background species
         ONE_D%RHO_F = PBAR_P(KK,ONE_D%PRESSURE_ZONE)/(RSUM0*ONE_D%TMP_F)
         ONE_D%ZZ_F(1) = 1._EB
         UN = MFT/ONE_D%RHO_F
      ELSEIF (PRESENT(WALL_INDEX) .AND. .NOT.SOLID(IC) .AND. .NOT.EXTERIOR(IC)) THEN  ! this is a thin obstruction
         UN = 0._EB
         ONE_D%ZZ_F(:) = ZZ_G(:)
         IF (CORRECTOR) THEN  ! calculate the mass production rate of gases in the adjacent gas cell
            RVC = RDX(IIG)*RRN(IIG)*RDY(JJG)*RDZ(KKG)
            DO NS=1,N_TRACKED_SPECIES
               IF (ABS(ONE_D%M_DOT_G_PP_ADJUST(NS))<=TWO_EPSILON_EB) CYCLE
               MW_RATIO = SPECIES_MIXTURE(NS)%RCON/RSUM(IIG,JJG,KKG)
               M_DOT_PPP_SINGLE = ONE_D%M_DOT_G_PP_ADJUST(NS)*ONE_D%AREA*RVC
               D_SOURCE(IIG,JJG,KKG) = D_SOURCE(IIG,JJG,KKG) + M_DOT_PPP_SINGLE*MW_RATIO/RHO_G
               M_DOT_PPP(IIG,JJG,KKG,NS) = M_DOT_PPP(IIG,JJG,KKG,NS) + M_DOT_PPP_SINGLE
            ENDDO
            ZZ_GET(1:N_TRACKED_SPECIES) = ZZ_G(1:N_TRACKED_SPECIES)
            CALL GET_SPECIFIC_HEAT(ZZ_GET,CP,TMP_G)
            H_G = CP*TMP_G
            D_SOURCE(IIG,JJG,KKG) = D_SOURCE(IIG,JJG,KKG) - ONE_D%Q_DOT_G_PP*ONE_D%AREA*RVC/(H_G*RHO_G)
         ENDIF
      ELSE
         RHO_F_PREVIOUS = ONE_D%RHO_F
         DO ITER=1,3
            UN = MFT/ONE_D%RHO_F
            SPECIES_LOOP: DO N=1,N_TRACKED_SPECIES
               ONE_D%RHO_D_F(N) = ONE_D%RHO_D_F(N)*ONE_D%RHO_F/RHO_F_PREVIOUS
               DD = 2._EB*ONE_D%RHO_D_F(N)*ONE_D%RDN
               DENOM = DD + UN*ONE_D%RHO_F
               IF ( ABS(DENOM) > TWO_EPSILON_EB ) THEN
                  ONE_D%ZZ_F(N) = ( ONE_D%M_DOT_G_PP_ADJUST(N) + DD*ZZ_G(N) ) / DENOM
               ELSE
                  ONE_D%ZZ_F(N) = ZZ_G(N)
               ENDIF
            ENDDO SPECIES_LOOP
            CALL GET_REALIZABLE_MF(ONE_D%ZZ_F)
            ZZ_GET(1:N_TRACKED_SPECIES) = ONE_D%ZZ_F(1:N_TRACKED_SPECIES)
            CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM_F)
            RHO_F_PREVIOUS = ONE_D%RHO_F
            ONE_D%RHO_F = PBAR_P(KK,ONE_D%PRESSURE_ZONE)/(RSUM_F*ONE_D%TMP_F)
         ENDDO
      ENDIF

      IF (PREDICTOR) ONE_D%U_NORMAL_S = -UN
      IF (CORRECTOR) ONE_D%U_NORMAL  = -UN

END SELECT METHOD_OF_MASS_TRANSFER

END SUBROUTINE CALCULATE_ZZ_F

END SUBROUTINE SPECIES_BC


SUBROUTINE DENSITY_BC

! Compute density at wall from wall temperatures and mass fractions

USE PHYSICAL_FUNCTIONS, ONLY : GET_SPECIFIC_GAS_CONSTANT
REAL(EB) :: ZZ_GET(1:N_TRACKED_SPECIES),RSUM_F,UN_P,RHO_G,ZZ_G(1:N_TRACKED_SPECIES)
INTEGER  :: IW,BOUNDARY_TYPE,ICF
REAL(EB), POINTER, DIMENSION(:,:) :: PBAR_P
REAL(EB), POINTER, DIMENSION(:,:,:) :: RHOP
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP

IF (PREDICTOR) THEN
   PBAR_P => PBAR_S
   RHOP => RHOS
   ZZP => ZZS
ELSE
   PBAR_P => PBAR
   RHOP => RHO
   ZZP => ZZ
ENDIF

! Loop over all wall cells

WALL_CELL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS
   WC => WALL(IW)
   BOUNDARY_TYPE = WC%BOUNDARY_TYPE
   IF (BOUNDARY_TYPE==NULL_BOUNDARY .OR. BOUNDARY_TYPE==INTERPOLATED_BOUNDARY) CYCLE WALL_CELL_LOOP
   ONE_D => BOUNDARY_ONE_D(WC%OD_INDEX)
   BC => BOUNDARY_COORD(WC%BC_INDEX)
   RHO_G = RHOP(BC%IIG,BC%JJG,BC%KKG)
   ZZ_G(1:N_TRACKED_SPECIES) = ZZP(BC%IIG,BC%JJG,BC%KKG,1:N_TRACKED_SPECIES)
   CALL CALCULATE_RHO_F
   IF (IW<=N_EXTERNAL_WALL_CELLS .AND. BOUNDARY_TYPE/=OPEN_BOUNDARY) RHOP(BC%II,BC%JJ,BC%KK) = 2._EB*ONE_D%RHO_F - RHO_G
ENDDO WALL_CELL_LOOP

! Loop over all cut face cells

CFACE_LOOP: DO ICF=N_EXTERNAL_CFACE_CELLS+1,N_EXTERNAL_CFACE_CELLS+N_INTERNAL_CFACE_CELLS
   CFA => CFACE(ICF)
   BOUNDARY_TYPE = CFA%BOUNDARY_TYPE
   ONE_D => BOUNDARY_ONE_D(CFA%OD_INDEX)
   RHO_G = CFA%RHO_G
   ZZ_G  = CFA%ZZ_G
   BC => BOUNDARY_COORD(CFA%BC_INDEX)
   CALL CALCULATE_RHO_F
ENDDO CFACE_LOOP

CONTAINS

SUBROUTINE CALCULATE_RHO_F

! Compute density, RHO_F, at non-iterpolated boundaries

ZZ_GET(1:N_TRACKED_SPECIES) = MAX(0._EB,ONE_D%ZZ_F(1:N_TRACKED_SPECIES))
CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM_F)
ONE_D%RHO_F = PBAR_P(BC%KK,ONE_D%PRESSURE_ZONE)/(RSUM_F*ONE_D%TMP_F)

! If the boundary is solid and gas is being drawn in, set surface variables to equal the adjacent gas phase variables

IF (BOUNDARY_TYPE==SOLID_BOUNDARY) THEN
   IF (PREDICTOR) THEN
      UN_P = ONE_D%U_NORMAL_S
   ELSE
      UN_P = ONE_D%U_NORMAL
   ENDIF
   IF (UN_P>0._EB) THEN
      ONE_D%ZZ_F(1:N_TRACKED_SPECIES) = ZZ_G(1:N_TRACKED_SPECIES)
      ONE_D%RHO_F = RHO_G
   ENDIF
ENDIF

END SUBROUTINE CALCULATE_RHO_F

END SUBROUTINE DENSITY_BC


SUBROUTINE HVAC_BC

! Compute density at wall from wall temperatures and mass fractions

USE HVAC_ROUTINES, ONLY : NODE_AREA_EX,NODE_TMP_EX,DUCT_MF,NODE_ZZ_EX
USE PHYSICAL_FUNCTIONS, ONLY : GET_SPECIFIC_GAS_CONSTANT,GET_ENTHALPY
REAL(EB) :: ZZ_GET(1:N_TRACKED_SPECIES),UN,MFT,RSUM_F,H_D,H_G,TMP_G,ZZ_G(1:N_TRACKED_SPECIES)
INTEGER  :: IW,KK,SURF_INDEX,COUNTER,DU,ICF
REAL(EB), POINTER :: Q_LEAK
REAL(EB), POINTER, DIMENSION(:,:) :: PBAR_P
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP

IF (PREDICTOR) THEN
   PBAR_P => PBAR_S
   ZZP => ZZS
ELSE
   PBAR_P => PBAR
   ZZP => ZZ
ENDIF

! Loop over all internal and external wall cells

WALL_CELL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS
   WC => WALL(IW)
   ONE_D => BOUNDARY_ONE_D(WC%OD_INDEX)
   IF (ONE_D%NODE_INDEX == 0) CYCLE WALL_CELL_LOOP
   BC => BOUNDARY_COORD(WC%BC_INDEX)
   SURF_INDEX = WC%SURF_INDEX
   Q_LEAK => WC%Q_LEAK
   TMP_G = TMP(BC%IIG,BC%JJG,BC%KKG)
   ZZ_G(1:N_TRACKED_SPECIES) = ZZP(BC%IIG,BC%JJG,BC%KKG,1:N_TRACKED_SPECIES)
   CALL CALC_HVAC_BC
ENDDO WALL_CELL_LOOP

CFACE_LOOP: DO ICF=N_EXTERNAL_CFACE_CELLS+1,N_EXTERNAL_CFACE_CELLS+N_INTERNAL_CFACE_CELLS
   CFA => CFACE(ICF)
   ONE_D => BOUNDARY_ONE_D(CFA%OD_INDEX)
   IF (ONE_D%NODE_INDEX == 0) CYCLE CFACE_LOOP
   BC => BOUNDARY_COORD(CFA%BC_INDEX)
   SURF_INDEX = CFA%SURF_INDEX
   Q_LEAK => CFA%Q_LEAK
   TMP_G = CFA%TMP_G
   ZZ_G  = CFA%ZZ_G
   CALL CALC_HVAC_BC
ENDDO CFACE_LOOP

CONTAINS

SUBROUTINE CALC_HVAC_BC

SF => SURFACE(SURF_INDEX)
KK  = BC%KK
COUNTER = 0

! Compute R*Sum(Y_i/W_i) at the wall

DU=DUCTNODE(ONE_D%NODE_INDEX)%DUCT_INDEX(1)
MFT = -DUCTNODE(ONE_D%NODE_INDEX)%DIR(1)*DUCT_MF(DU)/NODE_AREA_EX(ONE_D%NODE_INDEX)
IF (.NOT. ANY(SF%LEAK_PATH>0)) THEN
   IF (DUCTNODE(ONE_D%NODE_INDEX)%DIR(1)*DUCT_MF(DU) > 0._EB) THEN
      IF (SF%THERMAL_BC_INDEX==HVAC_BOUNDARY) THEN
         ONE_D%TMP_F = NODE_TMP_EX(ONE_D%NODE_INDEX)
         ONE_D%HEAT_TRANS_COEF = 0._EB
         ONE_D%Q_CON_F = 0._EB
      ELSE
         IF (DUCT(DU)%LEAK_ENTHALPY) THEN
            ZZ_GET(1:N_TRACKED_SPECIES) = NODE_ZZ_EX(ONE_D%NODE_INDEX,1:N_TRACKED_SPECIES)
            CALL GET_ENTHALPY(ZZ_GET,H_G,ONE_D%TMP_F)
            CALL GET_ENTHALPY(ZZ_GET,H_D,NODE_TMP_EX(ONE_D%NODE_INDEX))
            Q_LEAK = -MFT*(H_D-H_G)*ONE_D%RDN
         ENDIF
      ENDIF
   ELSE
      IF (SF%THERMAL_BC_INDEX==HVAC_BOUNDARY) THEN
         ONE_D%TMP_F = TMP_G
         ONE_D%HEAT_TRANS_COEF = 0._EB
         ONE_D%Q_CON_F = 0._EB
      ENDIF
   ENDIF
ENDIF

IF (MFT >= 0._EB) THEN
   ZZ_GET(1:N_TRACKED_SPECIES) = ZZ_G(1:N_TRACKED_SPECIES)
   CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM_F)
   ONE_D%RHO_F = PBAR_P(KK,ONE_D%PRESSURE_ZONE)/(RSUM_F*TMP_G)
   UN = MFT/ONE_D%RHO_F
   IF (PREDICTOR) ONE_D%U_NORMAL_S = UN
   IF (CORRECTOR) ONE_D%U_NORMAL  = UN
ELSE
   ONE_D%M_DOT_G_PP_ADJUST(1:N_TRACKED_SPECIES) = -NODE_ZZ_EX(ONE_D%NODE_INDEX,1:N_TRACKED_SPECIES)*MFT
ENDIF

END SUBROUTINE CALC_HVAC_BC

END SUBROUTINE HVAC_BC


!> \brief Update temperature and material components for a single boundary cell
!>
!> \param NM Mesh number
!> \param T Current time (s)
!> \param DT_BC Time step (s) used for solid phase updates
!> \param PARTICLE_INDEX Index of a Lagrangian particle
!> \param WALL_INDEX Index of a Cartesian WALL cell
!> \param CFACE_INDEX Index of an immersed boundary CFACE

SUBROUTINE SOLID_HEAT_TRANSFER_1D(NM,T,DT_BC,PARTICLE_INDEX,WALL_INDEX,CFACE_INDEX)

USE GEOMETRY_FUNCTIONS
USE MATH_FUNCTIONS, ONLY: EVALUATE_RAMP, INTERPOLATE1D_UNIFORM
USE COMP_FUNCTIONS, ONLY: SHUTDOWN
USE PHYSICAL_FUNCTIONS, ONLY: GET_SPECIFIC_GAS_CONSTANT,GET_SENSIBLE_ENTHALPY
REAL(EB), INTENT(IN) :: DT_BC,T
INTEGER, INTENT(IN) :: NM
INTEGER, INTENT(IN), OPTIONAL:: WALL_INDEX,PARTICLE_INDEX,CFACE_INDEX
REAL(EB) :: DTMP,QDXKF,QDXKB,RR,RFACF,RFACB,RFACF2,RFACB2, &
            Q_RAD_IN_B,RFLUX_UP,RFLUX_DOWN,E_WALLB, &
            VOLSUM,KAPSUM,REGRID_MAX,REGRID_SUM,  &
            DXF,DXB,HTCF,HTCB,Q_RAD_OUT,Q_RAD_OUT_OLD,Q_CON_F,Q_CON_B,Q_WATER_F,Q_WATER_B,LAYER_DIVIDE,TMP_BACK,&
            M_DOT_G_PPP_ADJUST(N_TRACKED_SPECIES),M_DOT_G_PPP_ACTUAL(N_TRACKED_SPECIES),&
            M_DOT_G_PP_ADJUST(N_TRACKED_SPECIES),M_DOT_G_PP_ACTUAL(N_TRACKED_SPECIES),&
            M_DOT_S_PPP(MAX_MATERIALS),M_DOT_S_PP(MAX_MATERIALS),GEOM_FACTOR,RHO_TEMP(MAX_MATERIALS),RHO_DOT_TEMP(MAX_MATERIALS),&
            DEL_DOT_Q_SC,Q_DOT_G_PPP,Q_DOT_O2_PPP,Q_DOT_G_PP,Q_DOT_O2_PP,R_SURF,U_SURF,V_SURF,W_SURF,T_BC_SUB,DT_BC_SUB,&
            Q_NET_F,Q_NET_B,TMP_RATIO,KODXF,KODXB,H_S,T_NODE,C_S,H_NODE,TMP_S(1:NWP_MAX),RHO_H_S(1:NWP_MAX),VOL,T_BOIL_EFF,&
            Q_DOT_PART(MAX_LPC),M_DOT_PART(MAX_LPC),Q_DOT_PART_S(MAX_LPC),M_DOT_PART_S(MAX_LPC),RADIUS,HTC_LIMIT,TMP_G,&
            ZZ_G(1:N_TRACKED_SPECIES),CP1,CP2,DENOM
REAL(EB) :: POROSITY(0:NWP_MAX+1),DDSUM, SMALLEST_CELL_SIZE(1:MAX_LAYERS)
REAL(EB), POINTER, DIMENSION(:) :: DELTA_TMP
INTEGER :: IIB,JJB,KKB,IWB,NWP,I,NR,NL,N,I_OBST,N_LAYER_CELLS_NEW(MAX_LAYERS),N_CELLS,EXPON,ITMP,ITER
REAL(EB) :: DX_MIN(MAX_LAYERS),THICKNESS
REAL(EB),ALLOCATABLE,DIMENSION(:,:) :: INT_WGT
INTEGER  :: NWP_NEW,I_GRAD,IZERO,SURF_INDEX,SURF_INDEX_BACK,BACKING
LOGICAL :: E_FOUND,CHANGE_THICKNESS,CONST_C(NWP_MAX),REMESH_LAYER(MAX_LAYERS),REMESH_CHECK
CHARACTER(MESSAGE_LENGTH) :: MESSAGE
TYPE(WALL_TYPE), POINTER :: WC_BACK
TYPE(CFACE_TYPE), POINTER :: CFA_BACK

! Copy commonly used derived type variables into local variables.

R_SURF=0._EB
U_SURF=0._EB
V_SURF=0._EB
W_SURF=0._EB

CONST_C = .TRUE.

DELTA_TMP => CCS

UNPACK_WALL_PARTICLE: IF (PRESENT(WALL_INDEX)) THEN

   WC => WALL(WALL_INDEX)
   SURF_INDEX = WC%SURF_INDEX
   SF => SURFACE(SURF_INDEX)
   ONE_D => BOUNDARY_ONE_D(WC%OD_INDEX)
   BP => BOUNDARY_PROPS(WC%BP_INDEX)
   BC => BOUNDARY_COORD(WC%BC_INDEX)
   I_OBST = WC%OBST_INDEX
   IWB = WC%BACK_INDEX  ! Wall cell index of backside of side
   IF (WC%BACK_INDEX>0 .AND. WC%BACK_MESH==NM) THEN
      WC_BACK => WALL(WC%BACK_INDEX)
      ONE_D_BACK => BOUNDARY_ONE_D(WC_BACK%OD_INDEX)
      BP_BACK => BOUNDARY_PROPS(WC_BACK%BP_INDEX)
      BC_BACK => BOUNDARY_COORD(WC_BACK%BC_INDEX)
      SURF_INDEX_BACK = WC_BACK%SURF_INDEX
   ENDIF
   BACKING = SF%BACKING
   IF (WC%BACK_INDEX==0 .AND. SF%BACKING==EXPOSED) BACKING = VOID
   TMP_G = TMP(BC%IIG,BC%JJG,BC%KKG)
   ZZ_G(1:N_TRACKED_SPECIES) = ZZ(BC%IIG,BC%JJG,BC%KKG,1:N_TRACKED_SPECIES)

   ! Take away energy flux due to water evaporation

   IF (NLP>0) THEN
      Q_WATER_F = -SUM(BP%LP_CPUA(:)) + ONE_D%Q_CONDENSE
   ELSE
      Q_WATER_F = ONE_D%Q_CONDENSE
   ENDIF

ELSEIF (PRESENT(CFACE_INDEX)) THEN UNPACK_WALL_PARTICLE

   CFA => CFACE(CFACE_INDEX)
   SURF_INDEX = CFA%SURF_INDEX
   SF => SURFACE(SURF_INDEX)
   ONE_D => BOUNDARY_ONE_D(CFA%OD_INDEX)
   BP => BOUNDARY_PROPS(CFA%BP_INDEX)
   BC => BOUNDARY_COORD(CFA%BC_INDEX)
   I_OBST = 0
   Q_WATER_F = ONE_D%Q_CONDENSE
   IF (CFA%BACK_INDEX>0 .AND. CFA%BACK_MESH==NM) THEN
      CFA_BACK => CFACE(CFA%BACK_INDEX)
      ONE_D_BACK => BOUNDARY_ONE_D(CFA_BACK%OD_INDEX)
      BP_BACK => BOUNDARY_PROPS(CFA_BACK%BP_INDEX)
      BC_BACK => BOUNDARY_COORD(CFA_BACK%BC_INDEX)
      SURF_INDEX_BACK = CFA_BACK%SURF_INDEX
   ENDIF
   BACKING = SF%BACKING
   IF (CFA%BACK_INDEX==0 .AND. SF%BACKING==EXPOSED) BACKING = VOID
   TMP_G = CFA%TMP_G
   ZZ_G  = CFA%ZZ_G

ELSEIF (PRESENT(PARTICLE_INDEX)) THEN UNPACK_WALL_PARTICLE

   LP => LAGRANGIAN_PARTICLE(PARTICLE_INDEX)
   ONE_D => BOUNDARY_ONE_D(LP%OD_INDEX)
   BC => BOUNDARY_COORD(LP%BC_INDEX)
   SURF_INDEX = LAGRANGIAN_PARTICLE_CLASS(LP%CLASS_INDEX)%SURF_INDEX
   SF => SURFACE(SURF_INDEX)
   I_OBST = 0
   BACKING = INSULATED
   Q_WATER_F = ONE_D%Q_CONDENSE
   R_SURF=SUM(ONE_D%LAYER_THICKNESS(1:SF%N_LAYERS))
   U_SURF=LP%U
   V_SURF=LP%V
   W_SURF=LP%W
   TMP_G = TMP(BC%IIG,BC%JJG,BC%KKG)
   ZZ_G(1:N_TRACKED_SPECIES) = ZZ(BC%IIG,BC%JJG,BC%KKG,1:N_TRACKED_SPECIES)

ENDIF UNPACK_WALL_PARTICLE

! If the fuel has burned away, return

IF (ONE_D%BURNAWAY) THEN
   ONE_D%M_DOT_G_PP_ADJUST(1:N_TRACKED_SPECIES) = 0._EB
   RETURN
ENDIF

! Special case where the gas temperature is fixed by the user

IF (ASSUMED_GAS_TEMPERATURE > 0._EB) TMP_G = TMPA + EVALUATE_RAMP(T-T_BEGIN,I_RAMP_AGT)*(ASSUMED_GAS_TEMPERATURE-TMPA)

! Exponents for cylindrical or spherical coordinates

SELECT CASE(SF%GEOMETRY)
   CASE(SURF_CARTESIAN)   ; I_GRAD = 1
   CASE(SURF_CYLINDRICAL) ; I_GRAD = 2
   CASE(SURF_SPHERICAL)   ; I_GRAD = 3
END SELECT

! Set mass and energy fluxes to zero prior to time sub-iteration

ONE_D%HEAT_TRANS_COEF = 0._EB
ONE_D%Q_CON_F = 0._EB
IF (SF%INTERNAL_RADIATION) THEN
   Q_RAD_OUT_OLD = ONE_D%Q_RAD_OUT
   ONE_D%Q_RAD_OUT = 0._EB
ENDIF

IF (SF%PYROLYSIS_MODEL==PYROLYSIS_PREDICTED) THEN
   IF (MATERIAL(SF%MATL_INDEX(1))%PYROLYSIS_MODEL==PYROLYSIS_LIQUID) THEN
      DO N=1,SF%N_MATL
         ONE_D%MATL_COMP(N)%RHO_DOT(:) = 0._EB
      ENDDO
   ENDIF
   ONE_D%M_DOT_G_PP_ADJUST(1:N_TRACKED_SPECIES) = 0._EB
   ONE_D%M_DOT_G_PP_ACTUAL(1:N_TRACKED_SPECIES) = 0._EB
   ONE_D%M_DOT_S_PP(1:SF%N_MATL)                = 0._EB
   ONE_D%Q_DOT_G_PP                             = 0._EB
   ONE_D%Q_DOT_O2_PP                            = 0._EB
   ONE_D%M_DOT_PART_ACTUAL                      = 0._EB
ENDIF

! Start time iterations here

T_BC_SUB  = 0._EB
DT_BC_SUB = DT_BC
ONE_D%N_SUBSTEPS = 1

SUB_TIMESTEP_LOOP: DO

! Compute grid for reacting nodes

LAYER_DIVIDE = SF%LAYER_DIVIDE

COMPUTE_GRID: IF (SF%PYROLYSIS_MODEL==PYROLYSIS_PREDICTED) THEN
   NWP = SUM(ONE_D%N_LAYER_CELLS(1:SF%N_LAYERS))
   CALL GET_WALL_NODE_WEIGHTS(NWP,SF%N_LAYERS,ONE_D%N_LAYER_CELLS(1:SF%N_LAYERS),ONE_D%LAYER_THICKNESS,SF%GEOMETRY, &
      ONE_D%X(0:NWP),LAYER_DIVIDE,DX_S(1:NWP),RDX_S(0:NWP+1),RDXN_S(0:NWP),DX_WGT_S(0:NWP),DXF,DXB,&
      LAYER_INDEX(0:NWP+1),MF_FRAC(1:NWP),SF%INNER_RADIUS)
ELSE COMPUTE_GRID
   NWP                  = SF%N_CELLS_INI
   DXF                  = SF%DXF
   DXB                  = SF%DXB
   DX_S(1:NWP)          = SF%DX(1:NWP)
   RDX_S(0:NWP+1)       = SF%RDX(0:NWP+1)
   RDXN_S(0:NWP)        = SF%RDXN(0:NWP)
   DX_WGT_S(0:NWP)      = SF%DX_WGT(0:NWP)
   LAYER_INDEX(0:NWP+1) = SF%LAYER_INDEX(0:NWP+1)
   MF_FRAC(1:NWP)       = SF%MF_FRAC(1:NWP)
ENDIF COMPUTE_GRID

! Compute convective heat flux at the surface

DTMP = TMP_G - ONE_D%TMP_F
IF (PRESENT(WALL_INDEX)) THEN
   HTCF = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SURF_INDEX,WALL_INDEX_IN=WALL_INDEX)
ELSEIF (PRESENT(CFACE_INDEX)) THEN
   HTCF = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SURF_INDEX,CFACE_INDEX_IN=CFACE_INDEX)
ELSEIF (PRESENT(PARTICLE_INDEX)) THEN
   RADIUS = SF%INNER_RADIUS + SUM(ONE_D%LAYER_THICKNESS(1:SF%N_LAYERS))
   SELECT CASE(SF%GEOMETRY)
      CASE (SURF_CARTESIAN)   ; HTC_LIMIT = 0.5_EB*RADIUS*ONE_D%RHO_C_S(1)/(      DT_BC_SUB)
      CASE (SURF_CYLINDRICAL) ; HTC_LIMIT = 0.5_EB*RADIUS*ONE_D%RHO_C_S(1)/(2._EB*DT_BC_SUB)
      CASE (SURF_SPHERICAL)   ; HTC_LIMIT = 0.5_EB*RADIUS*ONE_D%RHO_C_S(1)/(3._EB*DT_BC_SUB)
   END SELECT
   HTCF = MIN(HTC_LIMIT , HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SURF_INDEX,PARTICLE_INDEX_IN=PARTICLE_INDEX))
ENDIF
Q_CON_F = HTCF*DTMP

! Compute back side emissivity

E_WALLB = SF%EMISSIVITY_BACK
IF (E_WALLB < 0._EB .AND. BACKING /= INSULATED) THEN
   E_WALLB = 0._EB
   VOLSUM  = 0._EB
   DO N=1,SF%N_MATL
      IF (ONE_D%MATL_COMP(N)%RHO(NWP)<=TWO_EPSILON_EB) CYCLE
      ML => MATERIAL(SF%MATL_INDEX(N))
      VOLSUM  = VOLSUM  + ONE_D%MATL_COMP(N)%RHO(NWP)/SF%RHO_S(LAYER_INDEX(NWP),N)
      E_WALLB = E_WALLB + ONE_D%MATL_COMP(N)%RHO(NWP)*ML%EMISSIVITY/SF%RHO_S(LAYER_INDEX(NWP),N)
   ENDDO
   IF (VOLSUM > 0._EB) E_WALLB = E_WALLB/VOLSUM
ENDIF

! Get heat losses from convection and radiation out of back of surface

SELECT CASE(BACKING)

   CASE(VOID)  ! Non-insulated backing to an ambient void

      IF (SF%TMP_BACK>0._EB) THEN
         TMP_BACK = TMP_0(BC%KK) + EVALUATE_RAMP(T-T_BEGIN,SF%RAMP_T_B_INDEX)*(SF%TMP_BACK-TMP_0(BC%KK))
      ELSE
         TMP_BACK = TMP_0(BC%KK)
      ENDIF
      DTMP = TMP_BACK - ONE_D%TMP_B
      HTCB = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED_B,SURF_INDEX_IN=SURF_INDEX)
      Q_CON_B = HTCB*DTMP
      Q_RAD_IN_B   =  E_WALLB*SIGMA*TMP_BACK**4
      Q_WATER_B = 0._EB
      LAYER_DIVIDE = REAL(SF%N_LAYERS+1)
      MF_FRAC = 1._EB

   CASE(INSULATED)  ! No heat transfer out the back

      HTCB      = 0._EB
      Q_CON_B   = 0._EB
      Q_RAD_IN_B   = 0._EB
      E_WALLB   = 0._EB
      Q_WATER_B = 0._EB
      TMP_BACK = ONE_D%TMP_B

   CASE(EXPOSED)  ! The backside is exposed to gas in current or adjacent mesh.

      Q_WATER_B = 0._EB

      IF (WC%BACK_MESH/=NM .AND. WC%BACK_MESH>0) THEN  ! Back side is in other mesh.
         TMP_BACK = OMESH(WC%BACK_MESH)%EXPOSED_WALL(IWB)%TMP_GAS
         DTMP = TMP_BACK - ONE_D%TMP_B
         HTCB = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED_B,SURF_INDEX_IN=SURF_INDEX)
         Q_RAD_IN_B  = OMESH(WC%BACK_MESH)%EXPOSED_WALL(IWB)%Q_RAD_IN
      ELSE  ! Back side is in current mesh.
         IIB = BC_BACK%IIG
         JJB = BC_BACK%JJG
         KKB = BC_BACK%KKG
         TMP_BACK  = TMP(IIB,JJB,KKB)
         DTMP = TMP_BACK - ONE_D%TMP_B
         IF (PRESENT(WALL_INDEX)) &
            HTCB = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED_B,SURF_INDEX_IN=SURF_INDEX_BACK,WALL_INDEX_IN=WC%BACK_INDEX)
         IF (PRESENT(CFACE_INDEX)) &
            HTCB = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED_B,SURF_INDEX_IN=SURF_INDEX_BACK,CFACE_INDEX_IN=CFA%BACK_INDEX)
         ONE_D_BACK%HEAT_TRANS_COEF = HTCB
         Q_RAD_IN_B  = ONE_D_BACK%Q_RAD_IN
         IF (NLP>0) Q_WATER_B = -SUM(BP_BACK%LP_CPUA(:)) + ONE_D%Q_CONDENSE
      ENDIF
      Q_CON_B = HTCB*DTMP

END SELECT

! Get total thickness of solid and compute radius for cylindrical and spherical coordinate systems.

THICKNESS = SUM(ONE_D%LAYER_THICKNESS(1:SF%N_LAYERS))

DO I=0,NWP
   R_S(I) = SF%INNER_RADIUS + ONE_D%X(NWP) - ONE_D%X(I)
ENDDO

! Calculate reaction rates based on the solid phase reactions

Q_S = 0._EB

PYROLYSIS_PREDICTED_IF: IF (SF%PYROLYSIS_MODEL==PYROLYSIS_PREDICTED) THEN

   ! Set mass and energy fluxes to zero for this time sub-iteration

   M_DOT_G_PP_ADJUST(1:N_TRACKED_SPECIES) = 0._EB
   M_DOT_G_PP_ACTUAL(1:N_TRACKED_SPECIES) = 0._EB
   M_DOT_S_PP(1:SF%N_MATL)                = 0._EB
   Q_DOT_G_PP                             = 0._EB
   Q_DOT_O2_PP                            = 0._EB
   M_DOT_PART_S                           = 0._EB
   Q_DOT_PART_S                           = 0._EB

   ! Loop over all solid cells and compute the reaction rate of each material component, RHO_DOT_TEMP(N)

   POINT_LOOP1: DO I=1,NWP

      ! Create a temporary array to hold the material component densities at the current depth layer, I

      DO N=1,SF%N_MATL
         RHO_TEMP(N) = ONE_D%MATL_COMP(N)%RHO(I)
      ENDDO

      IF (PRESENT(PARTICLE_INDEX)) THEN
         CALL PYROLYSIS(SF%N_MATL,SF%MATL_INDEX,SURF_INDEX,BC%IIG,BC%JJG,BC%KKG,ONE_D%TMP(I),ONE_D%TMP_F,BC%IOR,&
                        RHO_DOT_TEMP(1:SF%N_MATL),RHO_TEMP(1:SF%N_MATL),ONE_D%X(I-1),DT_BC-T_BC_SUB,&
                        M_DOT_G_PPP_ADJUST,M_DOT_G_PPP_ACTUAL,M_DOT_S_PPP,Q_S(I),Q_DOT_G_PPP,Q_DOT_O2_PPP,&
                        Q_DOT_PART,M_DOT_PART,T_BOIL_EFF,ONE_D%B_NUMBER,LAYER_INDEX(I),SOLID_CELL_INDEX=I,&
                        R_DROP=R_SURF,LPU=U_SURF,LPV=V_SURF,LPW=W_SURF)
      ELSE
         CALL PYROLYSIS(SF%N_MATL,SF%MATL_INDEX,SURF_INDEX,BC%IIG,BC%JJG,BC%KKG,ONE_D%TMP(I),ONE_D%TMP_F,BC%IOR,&
                        RHO_DOT_TEMP(1:SF%N_MATL),RHO_TEMP(1:SF%N_MATL),ONE_D%X(I-1),DT_BC-T_BC_SUB,&
                        M_DOT_G_PPP_ADJUST,M_DOT_G_PPP_ACTUAL,M_DOT_S_PPP,Q_S(I),Q_DOT_G_PPP,Q_DOT_O2_PPP,&
                        Q_DOT_PART,M_DOT_PART,T_BOIL_EFF,ONE_D%B_NUMBER,LAYER_INDEX(I),SOLID_CELL_INDEX=I)
      ENDIF

      DO N=1,SF%N_MATL
         ONE_D%MATL_COMP(N)%RHO_DOT(I) = RHO_DOT_TEMP(N)
      ENDDO

      ! Compute the mass flux of reaction gases at the surface

      GEOM_FACTOR = MF_FRAC(I)*(R_S(I-1)**I_GRAD-R_S(I)**I_GRAD)/(I_GRAD*(SF%THICKNESS+SF%INNER_RADIUS)**(I_GRAD-1))
      Q_DOT_G_PP  = Q_DOT_G_PP  + Q_DOT_G_PPP*GEOM_FACTOR
      Q_DOT_O2_PP = Q_DOT_O2_PP + Q_DOT_O2_PPP*GEOM_FACTOR

      M_DOT_G_PP_ADJUST = M_DOT_G_PP_ADJUST + M_DOT_G_PPP_ADJUST*GEOM_FACTOR
      M_DOT_G_PP_ACTUAL = M_DOT_G_PP_ACTUAL + M_DOT_G_PPP_ACTUAL*GEOM_FACTOR

      M_DOT_S_PP(1:SF%N_MATL) = M_DOT_S_PP(1:SF%N_MATL)  + M_DOT_S_PPP(1:SF%N_MATL)*GEOM_FACTOR

      ! Compute particle mass flux at the surface
      IF (SF%N_LPC > 0) THEN
         GEOM_FACTOR = MF_FRAC(I)*(R_S(I-1)**I_GRAD-R_S(I)**I_GRAD)/(I_GRAD*(SF%THICKNESS+SF%INNER_RADIUS)**(I_GRAD-1))
         M_DOT_PART_S(1:SF%N_LPC) = M_DOT_PART_S(1:SF%N_LPC) + GEOM_FACTOR * M_DOT_PART(1:SF%N_LPC)
         Q_DOT_PART_S(1:SF%N_LPC) = Q_DOT_PART_S(1:SF%N_LPC) + GEOM_FACTOR * Q_DOT_PART(1:SF%N_LPC)
      ENDIF

   ENDDO POINT_LOOP1

ELSEIF (SF%PYROLYSIS_MODEL==PYROLYSIS_SPECIFIED) THEN PYROLYSIS_PREDICTED_IF

   ! Take off energy corresponding to specified burning rate

   Q_S(1) = Q_S(1) - ONE_D%M_DOT_G_PP_ADJUST(REACTION(1)%FUEL_SMIX_INDEX)*SF%H_V/DX_S(1)

ENDIF PYROLYSIS_PREDICTED_IF

! Add internal heat source specified by user

IF (SF%SPECIFIED_HEAT_SOURCE) Q_S(1:NWP) = Q_S(1:NWP)+SF%INTERNAL_HEAT_SOURCE(LAYER_INDEX(1:NWP))

! Add special convection term for Boundary Fuel Model

IF (SF%BOUNDARY_FUEL_MODEL) THEN
   HTCF = 0._EB
   HTCB = 0._EB
   Q_CON_F = 0._EB
   Q_CON_B = 0._EB
   DO I=1,NWP
      IF (SF%PACKING_RATIO(LAYER_INDEX(I))<0._EB) CYCLE
      DTMP = TMP(BC%IIG,BC%JJG,BC%KKG) - ONE_D%TMP(I)
      DEL_DOT_Q_SC = HEAT_TRANSFER_COEFFICIENT(DTMP,SF%H_FIXED,SURF_INDEX,WALL_INDEX_IN=WALL_INDEX)*DTMP
      Q_S(I) = Q_S(I) + SF%SURFACE_VOLUME_RATIO(LAYER_INDEX(I))*SF%PACKING_RATIO(LAYER_INDEX(I))*DEL_DOT_Q_SC
   ENDDO
ENDIF

! Calculate internal radiation for Cartesian geometry only

IF (SF%INTERNAL_RADIATION .AND. (SF%NUMBER_FSK_POINTS>0)) THEN
   ! Full spectrum k-distribution method
   ! Loop over FSK quadrature points
   Q_RAD_OUT = 0._EB
   DO NR = 1,SF%NUMBER_FSK_POINTS
      TWO_DX_KAPPA_S = 0._EB

      TWO_DX_KAPPA_S(1:NWP) = 2._EB*SF%FSK_K(NR)/RDX_S(1:NWP)

      ! solution inwards
      RFLUX_UP = SF%FSK_A(NR)*ONE_D%Q_RAD_IN + (1._EB-ONE_D%EMISSIVITY)*Q_RAD_OUT/(ONE_D%EMISSIVITY+1.0E-10_EB)
      DO I=1,NWP
         RFLUX_DOWN =  ( RFLUX_UP + SF%FSK_A(NR)*TWO_DX_KAPPA_S(I)*SIGMA*ONE_D%TMP(I)**4 ) / (1._EB + TWO_DX_KAPPA_S(I))
         Q_S(I) = Q_S(I) + SF%FSK_W(NR)*(RFLUX_UP - RFLUX_DOWN)*RDX_S(I)
         RFLUX_UP = RFLUX_DOWN
      ENDDO
      ! solution outwards
      RFLUX_UP = SF%FSK_A(NR)*Q_RAD_IN_B + (1._EB-E_WALLB)*RFLUX_UP
      DO I=NWP,1,-1
         RFLUX_DOWN =  ( RFLUX_UP + SF%FSK_A(NR)*TWO_DX_KAPPA_S(I)*SIGMA*ONE_D%TMP(I)**4 ) / (1._EB + TWO_DX_KAPPA_S(I))
         Q_S(I) = Q_S(I) + SF%FSK_W(NR)*(RFLUX_UP - RFLUX_DOWN)*RDX_S(I)
         RFLUX_UP = RFLUX_DOWN
      ENDDO
      Q_RAD_OUT = Q_RAD_OUT + SF%FSK_W(NR)*ONE_D%EMISSIVITY*RFLUX_DOWN
   ENDDO
ELSEIF (SF%INTERNAL_RADIATION .AND. (SF%NUMBER_FSK_POINTS == 0)) THEN
   ! Gray medium method
   DO I=1,NWP
      IF (SF%KAPPA_S(LAYER_INDEX(I))<0._EB) THEN
         VOLSUM = 0._EB
         KAPSUM = 0._EB
         DO N=1,SF%N_MATL
            IF (ONE_D%MATL_COMP(N)%RHO(I)<=TWO_EPSILON_EB) CYCLE
            ML  => MATERIAL(SF%MATL_INDEX(N))
            VOLSUM = VOLSUM + ONE_D%MATL_COMP(N)%RHO(I)/SF%RHO_S(LAYER_INDEX(I),N)
            KAPSUM = KAPSUM + ONE_D%MATL_COMP(N)%RHO(I)*ML%KAPPA_S/SF%RHO_S(LAYER_INDEX(I),N)
         ENDDO
         IF (VOLSUM>0._EB) TWO_DX_KAPPA_S(I) = 2._EB*KAPSUM/(RDX_S(I)*VOLSUM)
      ELSE
         TWO_DX_KAPPA_S(I) = 2._EB*SF%KAPPA_S(LAYER_INDEX(I))/RDX_S(I)
      ENDIF
   ENDDO
   ! solution inwards
   RFLUX_UP = ONE_D%Q_RAD_IN + (1._EB-ONE_D%EMISSIVITY)*Q_RAD_OUT_OLD/(ONE_D%EMISSIVITY+1.0E-10_EB)
   DO I=1,NWP
      RFLUX_DOWN =  ( RFLUX_UP + TWO_DX_KAPPA_S(I)*SIGMA*ONE_D%TMP(I)**4 ) / (1._EB + TWO_DX_KAPPA_S(I))
      Q_S(I) = Q_S(I) + (RFLUX_UP - RFLUX_DOWN)*RDX_S(I)
      RFLUX_UP = RFLUX_DOWN
   ENDDO
   ! solution outwards
   RFLUX_UP = Q_RAD_IN_B + (1._EB-E_WALLB)*RFLUX_UP
   DO I=NWP,1,-1
      RFLUX_DOWN =  ( RFLUX_UP + TWO_DX_KAPPA_S(I)*SIGMA*ONE_D%TMP(I)**4 ) / (1._EB + TWO_DX_KAPPA_S(I))
      Q_S(I) = Q_S(I) + (RFLUX_UP - RFLUX_DOWN)*RDX_S(I)
      RFLUX_UP = RFLUX_DOWN
   ENDDO
   Q_RAD_OUT = ONE_D%EMISSIVITY*RFLUX_DOWN
ENDIF

! Explicitly update the temperature field and adjust time step if the change in temperature exceeds DELTA_TMP_MAX

IF (ICYC>WALL_INCREMENT) THEN
   IF (SF%INTERNAL_RADIATION) THEN
      Q_NET_F = Q_CON_F
      Q_NET_B = Q_CON_B
   ELSE
      Q_NET_F = ONE_D%Q_RAD_IN - ONE_D%EMISSIVITY*SIGMA*ONE_D%TMP_F**4 + Q_CON_F
      Q_NET_B = Q_RAD_IN_B     - E_WALLB         *SIGMA*ONE_D%TMP_B**4 + Q_CON_B
   ENDIF
   DO I=2,NWP-1
      DELTA_TMP(I) = (DT_BC/ONE_D%RHO_C_S(I))*(RDX_S(I)*(ONE_D%K_S(I)  *RDXN_S(I)  *(ONE_D%TMP(I+1)-ONE_D%TMP(I))-&
                                                         ONE_D%K_S(I-1)*RDXN_S(I-1)*(ONE_D%TMP(I)-ONE_D%TMP(I-1))) + Q_S(I))
   ENDDO
   DELTA_TMP(1)   = (DT_BC/ONE_D%RHO_C_S(1))*&
                    (RDX_S(1)*(ONE_D%K_S(1)*RDXN_S(1)*(ONE_D%TMP(2)-ONE_D%TMP(1))+Q_NET_F) + Q_S(1))
   DELTA_TMP(NWP) = (DT_BC/ONE_D%RHO_C_S(NWP))*&
                    (RDX_S(NWP)*(-Q_NET_B-ONE_D%K_S(NWP-1)*RDXN_S(NWP-1)*(ONE_D%TMP(NWP)-ONE_D%TMP(NWP-1))) + Q_S(NWP))
   TMP_RATIO = MAX(TWO_EPSILON_EB,MAXVAL(ABS(DELTA_TMP(1:NWP)))/SF%DELTA_TMP_MAX)
   EXPON     = MIN(MAX(0,CEILING(LOG(TMP_RATIO)/LOG(2._EB))),SF%SUBSTEP_POWER)
   DT_BC_SUB = DT_BC/2._EB**EXPON
   DT_BC_SUB = MIN( DT_BC-T_BC_SUB , DT_BC_SUB )
ENDIF

T_BC_SUB = T_BC_SUB + DT_BC_SUB

! Store the mass and energy fluxes from this time sub-iteration

IF (SF%INTERNAL_RADIATION) THEN
   Q_RAD_OUT_OLD = Q_RAD_OUT
   ONE_D%Q_RAD_OUT = ONE_D%Q_RAD_OUT + Q_RAD_OUT*DT_BC_SUB/DT_BC
ENDIF

IF (SF%PYROLYSIS_MODEL==PYROLYSIS_PREDICTED) THEN
   ONE_D%Q_DOT_G_PP  = ONE_D%Q_DOT_G_PP  + Q_DOT_G_PP*DT_BC_SUB/DT_BC
   ONE_D%Q_DOT_O2_PP = ONE_D%Q_DOT_O2_PP + Q_DOT_O2_PP*DT_BC_SUB/DT_BC
   ONE_D%M_DOT_G_PP_ADJUST = ONE_D%M_DOT_G_PP_ADJUST + ONE_D%AREA_ADJUST*M_DOT_G_PP_ADJUST*DT_BC_SUB/DT_BC
   ONE_D%M_DOT_G_PP_ACTUAL = ONE_D%M_DOT_G_PP_ACTUAL +                   M_DOT_G_PP_ACTUAL*DT_BC_SUB/DT_BC

   ONE_D%M_DOT_S_PP(1:SF%N_MATL) = ONE_D%M_DOT_S_PP(1:SF%N_MATL) + M_DOT_S_PP(1:SF%N_MATL)*DT_BC_SUB/DT_BC
ENDIF

! Adjust the material layer masses and thicknesses

REMESH_LAYER = .FALSE.

PYROLYSIS_PREDICTED_IF_2: IF (SF%PYROLYSIS_MODEL==PYROLYSIS_PREDICTED) THEN

   ! Convert Q_S to kW
   DO I=1,NWP
      Q_S(I) = Q_S(I)*(R_S(I-1)**I_GRAD-R_S(I)**I_GRAD)
   ENDDO

   CHANGE_THICKNESS = .FALSE.

   POINT_LOOP2: DO I=1,NWP

      REGRID_FACTOR(I) = 1._EB
      REGRID_MAX       = 0._EB
      REGRID_SUM       = 0._EB

      ! Compute regrid factors

      MATERIAL_LOOP1a: DO N=1,SF%N_MATL
         ONE_D%MATL_COMP(N)%RHO(I) = MAX( 0._EB , ONE_D%MATL_COMP(N)%RHO(I) - DT_BC_SUB*ONE_D%MATL_COMP(N)%RHO_DOT(I) )
         REGRID_MAX = MAX(REGRID_MAX,ONE_D%MATL_COMP(N)%RHO(I)/SF%RHO_S(LAYER_INDEX(I),N))
         REGRID_SUM = REGRID_SUM + ONE_D%MATL_COMP(N)%RHO(I)/SF%RHO_S(LAYER_INDEX(I),N)
      ENDDO MATERIAL_LOOP1a
      IF (REGRID_SUM <= 1._EB) REGRID_FACTOR(I) = REGRID_SUM
      IF (REGRID_MAX >= ALMOST_ONE) REGRID_FACTOR(I) = REGRID_MAX

      ! If there is any non-shrinking material, the material matrix will remain, and no shrinking is allowed

      MATERIAL_LOOP1b: DO N=1,SF%N_MATL
         IF (ONE_D%MATL_COMP(N)%RHO(I)<=TWO_EPSILON_EB) CYCLE MATERIAL_LOOP1b
         ML  => MATERIAL(SF%MATL_INDEX(N))
         IF (.NOT. ML%ALLOW_SHRINKING) THEN
            REGRID_FACTOR(I) = MAX(REGRID_FACTOR(I),1._EB)
            EXIT MATERIAL_LOOP1b
         ENDIF
      ENDDO MATERIAL_LOOP1b

      ! If there is any non-swelling material, the material matrix will remain, and no swelling is allowed

      MATERIAL_LOOP1c: DO N=1,SF%N_MATL
         IF (ONE_D%MATL_COMP(N)%RHO(I)<=TWO_EPSILON_EB) CYCLE MATERIAL_LOOP1c
         ML  => MATERIAL(SF%MATL_INDEX(N))
         IF (.NOT. ML%ALLOW_SWELLING) THEN
            REGRID_FACTOR(I) = MIN(REGRID_FACTOR(I),1._EB)
            EXIT MATERIAL_LOOP1c
         ENDIF
      ENDDO MATERIAL_LOOP1c

      ! In points that change thickness, update the density

      IF (ABS(REGRID_FACTOR(I)-1._EB)>=TWO_EPSILON_EB) THEN
         CHANGE_THICKNESS=.TRUE.
         MATERIAL_LOOP1d: DO N=1,SF%N_MATL
            IF(REGRID_FACTOR(I)>TWO_EPSILON_EB) ONE_D%MATL_COMP(N)%RHO(I) = ONE_D%MATL_COMP(N)%RHO(I)/REGRID_FACTOR(I)
         ENDDO MATERIAL_LOOP1d
      ENDIF

   ENDDO POINT_LOOP2

   ! Compute new coordinates if the solid changes thickness. Save new coordinates in X_S_NEW.
   ! Remesh layer if any node goes to zero thickness

   R_S_NEW(NWP) = 0._EB
   DO I=NWP-1,0,-1
      R_S_NEW(I) = ( R_S_NEW(I+1)**I_GRAD + (R_S(I)**I_GRAD-R_S(I+1)**I_GRAD)*REGRID_FACTOR(I+1) )**(1./REAL(I_GRAD,EB))
   ENDDO

   X_S_NEW(0) = 0._EB
   DO I=1,NWP
      X_S_NEW(I) = R_S_NEW(0) - R_S_NEW(I)
      IF ((X_S_NEW(I)-X_S_NEW(I-1)) < TWO_EPSILON_EB) REMESH_LAYER(LAYER_INDEX(I)) = .TRUE.
   ENDDO

   !If any nodes go to zero, apportion Q_S to surrounding nodes.

   IF (ANY(REMESH_LAYER(1:SF%N_LAYERS)) .AND. NWP > 1) THEN
      IF (X_S_NEW(1)-X_S_NEW(0) < TWO_EPSILON_EB) Q_S(2) = Q_S(2) + Q_S(1)
      IF (X_S_NEW(NWP)-X_S_NEW(NWP-1) < TWO_EPSILON_EB) Q_S(NWP-1) = Q_S(NWP-1) + Q_S(NWP)
      DO I=2,NWP-1
         IF (X_S_NEW(I) - X_S_NEW(I-1) < TWO_EPSILON_EB) THEN
            N = 0
            IF (X_S_NEW(I-1) - X_S_NEW(I-2) > TWO_EPSILON_EB) N=N+1
            IF (X_S_NEW(I+1) - X_S_NEW(I) > TWO_EPSILON_EB) N=N+2
            SELECT CASE (N)
               CASE(1)
                  Q_S(I-1) = Q_S(I-1) + Q_S(I)
               CASE(2)
                  Q_S(I+1) = Q_S(I+1) + Q_S(I)
               CASE(3)
                  VOL = (R_S_NEW(I-1)**I_GRAD-R_S_NEW(I)**I_GRAD) / &
                        ((R_S_NEW(I-1)**I_GRAD-R_S_NEW(I)**I_GRAD)+(R_S_NEW(I)**I_GRAD-R_S_NEW(I+1)**I_GRAD))
                  Q_S(I-1) = Q_S(I-1) + Q_S(I) * VOL
                  Q_S(I+1) = Q_S(I+1) + Q_S(I) * (1._EB-VOL)
            END SELECT
         ENDIF
      ENDDO
   ENDIF

   ! Re-generate grid for a wall changing thickness

   N_LAYER_CELLS_NEW = 0
   DX_MIN = 0._EB

   REMESH_GRID: IF (CHANGE_THICKNESS) THEN
      NWP_NEW = 0
      THICKNESS = 0._EB

      I = 0
      LAYER_LOOP: DO NL=1,SF%N_LAYERS

         ONE_D%LAYER_THICKNESS(NL) = X_S_NEW(I+ONE_D%N_LAYER_CELLS(NL)) - X_S_NEW(I)
         ! Remove very thin layers

         IF (ONE_D%LAYER_THICKNESS(NL) < SF%MINIMUM_LAYER_THICKNESS) THEN
            X_S_NEW(I+ONE_D%N_LAYER_CELLS(NL):NWP) = X_S_NEW(I+ONE_D%N_LAYER_CELLS(NL):NWP)-ONE_D%LAYER_THICKNESS(NL)
            ONE_D%LAYER_THICKNESS(NL) = 0._EB
            IF (ONE_D%N_LAYER_CELLS(NL) > 0) REMESH_LAYER(NL) = .TRUE.
            N_LAYER_CELLS_NEW(NL) = 0
            NWP_NEW = NWP_NEW + N_LAYER_CELLS_NEW(NL)
            I = I + ONE_D%N_LAYER_CELLS(NL)
            CYCLE LAYER_LOOP
         ELSE

            ! If there is only one cell, nothing to do
            IF (ONE_D%N_LAYER_CELLS(NL)==1) THEN
               N_LAYER_CELLS_NEW(NL) = ONE_D%N_LAYER_CELLS(NL)
               NWP_NEW = NWP_NEW + N_LAYER_CELLS_NEW(NL)
               IF (ABS(REGRID_FACTOR(I+1)-1._EB) > TWO_EPSILON_EB) THEN
                  REMESH_LAYER(NL) = .TRUE.
                  N_LAYER_CELLS_NEW(NL) = 1
                  ONE_D%SMALLEST_CELL_SIZE(NL) = ONE_D%LAYER_THICKNESS(NL)
               ENDIF
               THICKNESS = THICKNESS + ONE_D%LAYER_THICKNESS(NL)
               I = I + ONE_D%N_LAYER_CELLS(NL)
               CYCLE LAYER_LOOP
            ENDIF

            ! If no cells in the layer have changed size, nothing to do
            IF (ALL(ABS(REGRID_FACTOR(I+1:I+ONE_D%N_LAYER_CELLS(NL))-1._EB) <= TWO_EPSILON_EB)) THEN
               N_LAYER_CELLS_NEW(NL) = ONE_D%N_LAYER_CELLS(NL)
               NWP_NEW = NWP_NEW + N_LAYER_CELLS_NEW(NL)
               THICKNESS = THICKNESS + ONE_D%LAYER_THICKNESS(NL)
               I = I + ONE_D%N_LAYER_CELLS(NL)
               CYCLE LAYER_LOOP
            ENDIF
         ENDIF

         ! Check if layer is expanding or contracting.
         EXPAND_CONTRACT: IF (ANY(REGRID_FACTOR(I+1:I+ONE_D%N_LAYER_CELLS(NL)) < 1._EB)) THEN
            ! At least one cell is contracting. Check to see if cells meets the RENODE_DELTA_T criterion
            REMESH_CHECK=.TRUE.
            DO N = I+1,I+ONE_D%N_LAYER_CELLS(NL)
               IF (ABS(ONE_D%TMP(N)-ONE_D%TMP(N-1))>SF%RENODE_DELTA_T(NL)) THEN
                  REMESH_CHECK = .FALSE.
                  EXIT
               ENDIF
            ENDDO
            REMESH_CHECK_IF: IF (REMESH_CHECK) THEN

               !If call cells in layer pass check, get new number of cells but limit decrease to at most one cell in a layer
               CALL GET_N_LAYER_CELLS(SF%MIN_DIFFUSIVITY(NL),ONE_D%LAYER_THICKNESS(NL), &
                  SF%STRETCH_FACTOR(NL),SF%CELL_SIZE_FACTOR,SF%N_LAYER_CELLS_MAX(NL),N_LAYER_CELLS_NEW(NL),SMALLEST_CELL_SIZE(NL),&
                  DDSUM)
                  LAYER_CELL_CHECK: IF (ONE_D%N_LAYER_CELLS(NL) - N_LAYER_CELLS_NEW(NL) > 1) THEN
                     N_LAYER_CELLS_NEW(NL) = ONE_D%N_LAYER_CELLS(NL)- 1
                     IF (MOD(N_LAYER_CELLS_NEW(NL),2)==0) THEN
                        DDSUM = 0._EB
                        DO N=1,N_LAYER_CELLS_NEW(NL)/2
                           DDSUM = DDSUM + SF%STRETCH_FACTOR(NL)**(N-1)
                        ENDDO
                        DDSUM = 2._EB*DDSUM
                     ELSE
                        DDSUM = 0._EB
                        DO N=1,(N_LAYER_CELLS_NEW(NL)-1)/2
                           DDSUM = DDSUM + SF%STRETCH_FACTOR(NL)**(N-1)
                        ENDDO
                        DDSUM = 2._EB*DDSUM + SF%STRETCH_FACTOR(NL)**((N_LAYER_CELLS_NEW(NL)-1)/2)
                     ENDIF
                     ONE_D%SMALLEST_CELL_SIZE(NL) = ONE_D%LAYER_THICKNESS(NL) / DDSUM
                     ONE_D%DDSUM(NL) = DDSUM
                     REMESH_LAYER(NL) = .TRUE.
                  ELSEIF (ONE_D%N_LAYER_CELLS(NL) - N_LAYER_CELLS_NEW(NL) == 1) THEN LAYER_CELL_CHECK
                     ONE_D%SMALLEST_CELL_SIZE(NL) = SMALLEST_CELL_SIZE(NL)
                     ONE_D%DDSUM(NL) = DDSUM
                     REMESH_LAYER(NL) = .TRUE.
                  ELSE LAYER_CELL_CHECK
                     N_LAYER_CELLS_NEW(NL) = ONE_D%N_LAYER_CELLS(NL)
                     ONE_D%SMALLEST_CELL_SIZE(NL) = ONE_D%LAYER_THICKNESS(NL) / ONE_D%DDSUM(NL)
                     REMESH_LAYER(NL) = .TRUE.
                  ENDIF LAYER_CELL_CHECK
            ELSE REMESH_CHECK_IF

               ! If at least one cell does not pass the check, keep the same number of cells but remesh.
               N_LAYER_CELLS_NEW(NL) = ONE_D%N_LAYER_CELLS(NL)
               ONE_D%SMALLEST_CELL_SIZE(NL) = ONE_D%LAYER_THICKNESS(NL) / ONE_D%DDSUM(NL)
               SMALLEST_CELL_SIZE(NL) = ONE_D%SMALLEST_CELL_SIZE(NL)
               REMESH_LAYER(NL) = .TRUE.
            ENDIF REMESH_CHECK_IF
            NWP_NEW = NWP_NEW + N_LAYER_CELLS_NEW(NL)

         ELSE EXPAND_CONTRACT
            !Since cells only expanding, there is no issue with remeshing layer
            CALL GET_N_LAYER_CELLS(SF%MIN_DIFFUSIVITY(NL),ONE_D%LAYER_THICKNESS(NL), &
               SF%STRETCH_FACTOR(NL),SF%CELL_SIZE_FACTOR,SF%N_LAYER_CELLS_MAX(NL),N_LAYER_CELLS_NEW(NL), &
               ONE_D%SMALLEST_CELL_SIZE(NL),ONE_D%DDSUM(NL))
               NWP_NEW = NWP_NEW + N_LAYER_CELLS_NEW(NL)
               REMESH_LAYER(NL) = .TRUE.
         ENDIF EXPAND_CONTRACT

         THICKNESS = THICKNESS + ONE_D%LAYER_THICKNESS(NL)
         I = I + ONE_D%N_LAYER_CELLS(NL)
      ENDDO LAYER_LOOP

      ! Check that NWP_NEW has not exceeded the allocated space N_CELLS_MAX

      IF (NWP_NEW > SF%N_CELLS_MAX) THEN
         WRITE(MESSAGE,'(A,I5,A,A)') 'ERROR: N_CELLS_MAX should be at least ',NWP_NEW,' for surface ',TRIM(SF%ID)
         CALL SHUTDOWN(MESSAGE,PROCESS_0_ONLY=.FALSE.)
      ENDIF

      ! Shrinking wall has gone to zero thickness.

      IF (THICKNESS <=TWO_EPSILON_EB) THEN
         ONE_D%TMP(0:NWP+1) = MAX(TMPMIN,TMP_BACK)
         ONE_D%TMP_F        = MIN(TMPMAX,MAX(TMPMIN,TMP_BACK))
         ONE_D%TMP_B        = MIN(TMPMAX,MAX(TMPMIN,TMP_BACK))
         ONE_D%Q_CON_F        = 0._EB
         ONE_D%M_DOT_G_PP_ADJUST(1:N_TRACKED_SPECIES) = 0._EB
         ONE_D%M_DOT_G_PP_ACTUAL(1:N_TRACKED_SPECIES) = 0._EB
         ONE_D%M_DOT_S_PP(1:SF%N_MATL) = 0._EB
         ONE_D%N_LAYER_CELLS(1:SF%N_LAYERS) = 0
         ONE_D%BURNAWAY          = .TRUE.
         ONE_D%PART_MASS(1:SF%N_LPC) = 0._EB
         ONE_D%PART_ENTHALPY(1:SF%N_LPC) = 0._EB
         ONE_D%T_MATL_PART = 0._EB
         ONE_D%M_DOT_PART_ACTUAL = 0._EB
         IF (I_OBST > 0) THEN
            IF (OBSTRUCTION(I_OBST)%CONSUMABLE) OBSTRUCTION(I_OBST)%MASS = -1.
         ENDIF
         RETURN
      ENDIF

      ! Set up new node points following shrinking/swelling

      ONE_D%X(0:NWP) = X_S_NEW(0:NWP)

      X_S_NEW = 0._EB
      REMESH_IF: IF (ANY(REMESH_LAYER)) THEN

         RHO_H_S = 0._EB
         TMP_S = 0._EB

         !Store wall enthalpy for later temperature extraction.

         DO I=1,NWP
            VOL = (THICKNESS+SF%INNER_RADIUS-ONE_D%X(I-1))**I_GRAD-(THICKNESS+SF%INNER_RADIUS-ONE_D%X(I))**I_GRAD
            MATL_REMESH: DO N=1,SF%N_MATL
               IF (ONE_D%MATL_COMP(N)%RHO(I)<=TWO_EPSILON_EB) CYCLE MATL_REMESH
               ML  => MATERIAL(SF%MATL_INDEX(N))
               ITMP = MIN(I_MAX_TEMP-1,INT(ONE_D%TMP(I)))
               H_S = ML%H(ITMP)+(ONE_D%TMP(I)-REAL(ITMP,EB))*(ML%H(ITMP+1)-ML%H(ITMP))
               RHO_H_S(I) = RHO_H_S(I) + ONE_D%MATL_COMP(N)%RHO(I) * H_S
            ENDDO MATL_REMESH
            RHO_H_S(I) = RHO_H_S(I) * VOL
            DO N=1,SF%N_MATL
               ONE_D%MATL_COMP(N)%RHO(I) = ONE_D%MATL_COMP(N)%RHO(I) * VOL
            ENDDO
            TMP_S(I)=ONE_D%TMP(I)*VOL
         ENDDO

         CALL GET_WALL_NODE_COORDINATES(NWP_NEW,NWP,SF%N_LAYERS,N_LAYER_CELLS_NEW,ONE_D%N_LAYER_CELLS, &
            ONE_D%SMALLEST_CELL_SIZE(1:SF%N_LAYERS),SF%STRETCH_FACTOR(1:SF%N_LAYERS),REMESH_LAYER(1:SF%N_LAYERS),&
            X_S_NEW(0:NWP_NEW),ONE_D%X(0:NWP))
         CALL GET_WALL_NODE_WEIGHTS(NWP_NEW,SF%N_LAYERS,N_LAYER_CELLS_NEW,ONE_D%LAYER_THICKNESS,SF%GEOMETRY, &
            X_S_NEW(0:NWP_NEW),LAYER_DIVIDE,DX_S(1:NWP_NEW),RDX_S(0:NWP_NEW+1),RDXN_S(0:NWP_NEW),&
            DX_WGT_S(0:NWP_NEW),DXF,DXB,LAYER_INDEX(0:NWP_NEW+1),MF_FRAC(1:NWP_NEW),SF%INNER_RADIUS)

         ! Interpolate densities and temperature from old grid to new grid

         ALLOCATE(INT_WGT(NWP_NEW,NWP),STAT=IZERO)
         CALL GET_INTERPOLATION_WEIGHTS(SF%GEOMETRY,NWP,NWP_NEW,SF%INNER_RADIUS,ONE_D%X(0:NWP),X_S_NEW(0:NWP_NEW),INT_WGT)
         N_CELLS = MAX(NWP,NWP_NEW)

         CALL INTERPOLATE_WALL_ARRAY(N_CELLS,NWP,NWP_NEW,INT_WGT,Q_S(1:N_CELLS))
         CALL INTERPOLATE_WALL_ARRAY(N_CELLS,NWP,NWP_NEW,INT_WGT,RHO_H_S(1:N_CELLS))
         CALL INTERPOLATE_WALL_ARRAY(N_CELLS,NWP,NWP_NEW,INT_WGT,TMP_S(1:N_CELLS))
         
         DO I=1,NWP_NEW
            VOL = (THICKNESS+SF%INNER_RADIUS-X_S_NEW(I-1))**I_GRAD-(THICKNESS+SF%INNER_RADIUS-X_S_NEW(I))**I_GRAD
            TMP_S(I) = TMP_S(I) / VOL
         ENDDO

         DO N=1,SF%N_MATL
            ML  => MATERIAL(SF%MATL_INDEX(N))
            CALL INTERPOLATE_WALL_ARRAY(N_CELLS,NWP,NWP_NEW,INT_WGT,ONE_D%MATL_COMP(N)%RHO(1:N_CELLS))
         ENDDO

         DEALLOCATE(INT_WGT)

         ! Extract temperature
         DO I=1,NWP_NEW
            H_NODE = RHO_H_S(I)
            T_NODE = TMP_S(I)
            ITER = 0
            T_SEARCH: DO
               ITER = ITER + 1
               C_S = 0._EB
               H_S = 0._EB
               CP1 = 0
               CP2 = 0
               ITMP = MIN(I_MAX_TEMP-1,INT(T_NODE))
               H_S = 0._EB
               T_S: DO N=1,SF%N_MATL
                  IF (ONE_D%MATL_COMP(N)%RHO(I)<=0._EB) CYCLE T_S
                  ML  => MATERIAL(SF%MATL_INDEX(N))
                  H_S = H_S + (ML%H(ITMP)+(T_NODE-REAL(ITMP,EB))*(ML%H(ITMP+1)-ML%H(ITMP)))*ONE_D%MATL_COMP(N)%RHO(I)
                  CP1 = CP1 + ML%H(ITMP)/REAL(ITMP,EB)*ONE_D%MATL_COMP(N)%RHO(I)
                  CP2 = CP2 + ML%H(ITMP+1)/REAL(ITMP+1,EB)*ONE_D%MATL_COMP(N)%RHO(I)
               ENDDO T_S
               C_S = H_S/T_NODE
               DENOM = C_S+T_NODE*(CP2-CP1)
               IF (ABS(DENOM) < TWO_EPSILON_EB) THEN
                  ONE_D%TMP(I) = T_NODE
               ELSE
                  ONE_D%TMP(I) = T_NODE + (H_NODE - H_S)/DENOM
               ENDIF
               IF (ABS(ONE_D%TMP(I) - T_NODE) < 0.0001_EB) EXIT T_SEARCH
               IF (ITER > 20) THEN
                  ONE_D%TMP(I) = 0.5_EB*(ONE_D%TMP(I)+T_NODE)
                  EXIT T_SEARCH
               ENDIF
               T_NODE = ONE_D%TMP(I)
            ENDDO T_SEARCH
            DO N=1,SF%N_MATL
               ONE_D%MATL_COMP(N)%RHO(I) = ONE_D%MATL_COMP(N)%RHO(I) /&
                  ((SF%INNER_RADIUS+X_S_NEW(NWP_NEW)-X_S_NEW(I-1))**I_GRAD-(SF%INNER_RADIUS+X_S_NEW(NWP_NEW)-X_S_NEW(I))**I_GRAD)
            ENDDO
         ENDDO

         ONE_D%TMP(0)         = 2._EB*ONE_D%TMP_F-ONE_D%TMP(1)   !Make sure front surface temperature stays the same
         ONE_D%TMP(NWP_NEW+1) = 2._EB*ONE_D%TMP_B-ONE_D%TMP(NWP_NEW) !Make sure back surface temperature stays the same

         ONE_D%N_LAYER_CELLS(1:SF%N_LAYERS) = N_LAYER_CELLS_NEW(1:SF%N_LAYERS)
         NWP = NWP_NEW
         ONE_D%X(0:NWP) = X_S_NEW(0:NWP)      ! Note: X(NWP+1...) are not set to zero.
      ELSE REMESH_IF
         CALL GET_WALL_NODE_WEIGHTS(NWP,SF%N_LAYERS,N_LAYER_CELLS_NEW,ONE_D%LAYER_THICKNESS(1:SF%N_LAYERS),SF%GEOMETRY, &
            ONE_D%X(0:NWP),LAYER_DIVIDE,DX_S(1:NWP),RDX_S(0:NWP+1),RDXN_S(0:NWP),DX_WGT_S(0:NWP),DXF,DXB, &
            LAYER_INDEX(0:NWP+1),MF_FRAC(1:NWP),SF%INNER_RADIUS)
      ENDIF REMESH_IF
   ENDIF REMESH_GRID

   ! Convert Q_S back to kW/m^3
   DO I=1,NWP
      Q_S(I) = Q_S(I)/((SF%INNER_RADIUS+ONE_D%X(NWP)-ONE_D%X(I-1))**I_GRAD-(SF%INNER_RADIUS+ONE_D%X(NWP)-ONE_D%X(I))**I_GRAD)
   ENDDO

ENDIF PYROLYSIS_PREDICTED_IF_2

! Calculate thermal properties

ONE_D%K_S = 0._EB
RHO_S   = 0._EB
ONE_D%RHO_C_S = 0._EB
ONE_D%EMISSIVITY = 0._EB
POROSITY = 0._EB
E_FOUND = .FALSE.

POINT_LOOP3: DO I=1,NWP
   VOLSUM = 0._EB
   ITMP = MIN(I_MAX_TEMP-1,INT(ONE_D%TMP(I)))
   MATERIAL_LOOP3: DO N=1,SF%N_MATL
      IF (ONE_D%MATL_COMP(N)%RHO(I)<=TWO_EPSILON_EB) CYCLE MATERIAL_LOOP3
      ML  => MATERIAL(SF%MATL_INDEX(N))
      VOLSUM = VOLSUM + ONE_D%MATL_COMP(N)%RHO(I)/SF%RHO_S(LAYER_INDEX(I),N)
      ONE_D%K_S(I) = ONE_D%K_S(I) + ONE_D%MATL_COMP(N)%RHO(I)*ML%K_S(ITMP)/SF%RHO_S(LAYER_INDEX(I),N)
      ONE_D%RHO_C_S(I) = ONE_D%RHO_C_S(I) + ONE_D%MATL_COMP(N)%RHO(I)*ML%C_S(ITMP)

      IF (.NOT.E_FOUND) ONE_D%EMISSIVITY = ONE_D%EMISSIVITY + ONE_D%MATL_COMP(N)%RHO(I)*ML%EMISSIVITY/SF%RHO_S(LAYER_INDEX(I),N)
      RHO_S(I) = RHO_S(I) + ONE_D%MATL_COMP(N)%RHO(I)
      POROSITY(I) = POROSITY(I) + ONE_D%MATL_COMP(N)%RHO(I)*ML%POROSITY/SF%RHO_S(LAYER_INDEX(I),N)
   ENDDO MATERIAL_LOOP3

   IF (VOLSUM > 0._EB) THEN
      ONE_D%K_S(I) = ONE_D%K_S(I)/VOLSUM
      POROSITY(I) = POROSITY(I)/VOLSUM
      IF (.NOT.E_FOUND) ONE_D%EMISSIVITY = ONE_D%EMISSIVITY/VOLSUM
   ENDIF
   IF (ONE_D%EMISSIVITY>=0._EB) E_FOUND = .TRUE.
   IF (ONE_D%K_S(I)<=TWO_EPSILON_EB)      ONE_D%K_S(I)      = 10000._EB
   IF (ONE_D%RHO_C_S(I)<=TWO_EPSILON_EB)  ONE_D%RHO_C_S(I)  = 0.001_EB

ENDDO POINT_LOOP3

! Calculate average K_S between at grid cell boundaries. Store result in K_S

ONE_D%K_S(0)     = ONE_D%K_S(1)
ONE_D%K_S(NWP+1) = ONE_D%K_S(NWP)
DO I=1,NWP-1
   ONE_D%K_S(I)  = 1._EB / ( DX_WGT_S(I)/ONE_D%K_S(I) + (1._EB-DX_WGT_S(I))/ONE_D%K_S(I+1) )
ENDDO

! Update the 1-D heat transfer equation

KODXF = ONE_D%K_S(0)/DXF
KODXB = ONE_D%K_S(NWP)/DXB

DO I=1,NWP
   BBS(I) = -0.5_EB*DT_BC_SUB*ONE_D%K_S(I-1)*RDXN_S(I-1)*RDX_S(I)/ONE_D%RHO_C_S(I)
   AAS(I) = -0.5_EB*DT_BC_SUB*ONE_D%K_S(I)  *RDXN_S(I)  *RDX_S(I)/ONE_D%RHO_C_S(I)
ENDDO
DDS(1:NWP) = 1._EB - AAS(1:NWP) - BBS(1:NWP)
DO I=1,NWP
   CCS(I) = ONE_D%TMP(I) - AAS(I)*(ONE_D%TMP(I+1)-ONE_D%TMP(I)) + BBS(I)*(ONE_D%TMP(I)-ONE_D%TMP(I-1)) &
            + DT_BC_SUB*Q_S(I)/ONE_D%RHO_C_S(I)
ENDDO

IF ( .NOT.RADIATION .OR. SF%INTERNAL_RADIATION ) THEN
   RFACF = 0.5_EB*HTCF
   RFACB = 0.5_EB*HTCB
ELSE
   RFACF = 0.5_EB*HTCF + 2._EB*ONE_D%EMISSIVITY*SIGMA*ONE_D%TMP_F**3
   RFACB = 0.5_EB*HTCB + 2._EB*E_WALLB*SIGMA*ONE_D%TMP_B**3
ENDIF
RFACF2 = (KODXF-RFACF)/(KODXF+RFACF)
RFACB2 = (KODXB-RFACB)/(KODXB+RFACB)
IF ( .NOT.RADIATION .OR. SF%INTERNAL_RADIATION ) THEN
   QDXKF = (HTCF*TMP_G + Q_WATER_F)/(KODXF+RFACF)
   QDXKB = (HTCB*TMP_BACK    + Q_WATER_B)/(KODXB+RFACB)
ELSE
   QDXKF = (HTCF*TMP_G + Q_WATER_F + ONE_D%Q_RAD_IN + 3._EB*ONE_D%EMISSIVITY*SIGMA*ONE_D%TMP_F**4) / (KODXF+RFACF)
   QDXKB = (HTCB*TMP_BACK    + Q_WATER_B + Q_RAD_IN_B     + 3._EB*E_WALLB*SIGMA*ONE_D%TMP_B**4         ) / (KODXB+RFACB)
ENDIF
CCS(1)   = CCS(1)   - BBS(1)  *QDXKF
CCS(NWP) = CCS(NWP) - AAS(NWP)*QDXKB
DDT(1:NWP) = DDS(1:NWP)
DDT(1)   = DDT(1)   + BBS(1)  *RFACF2
DDT(NWP) = DDT(NWP) + AAS(NWP)*RFACB2
TRIDIAGONAL_SOLVER_1: DO I=2,NWP
   RR     = BBS(I)/DDT(I-1)
   DDT(I) = DDT(I) - RR*AAS(I-1)
   CCS(I) = CCS(I) - RR*CCS(I-1)
ENDDO TRIDIAGONAL_SOLVER_1
CCS(NWP)  = CCS(NWP)/DDT(NWP)
TRIDIAGONAL_SOLVER_2: DO I=NWP-1,1,-1
   CCS(I) = (CCS(I) - AAS(I)*CCS(I+1))/DDT(I)
ENDDO TRIDIAGONAL_SOLVER_2

ONE_D%TMP(1:NWP) = MIN(TMPMAX,MAX(TMPMIN,CCS(1:NWP)))
ONE_D%TMP(0)     =            MAX(TMPMIN,ONE_D%TMP(1)  *RFACF2+QDXKF)  ! Ghost value, allow it to be large
ONE_D%TMP(NWP+1) =            MAX(TMPMIN,ONE_D%TMP(NWP)*RFACB2+QDXKB)  ! Ghost value, allow it to be large

ONE_D%Q_CON_F = ONE_D%Q_CON_F + HTCF*DT_BC_SUB*(TMP_G-0.5_EB*ONE_D%TMP_F)
ONE_D%TMP_F_OLD = ONE_D%TMP_F  ! Save this value for output of effective HTC

ONE_D%TMP_F  = 0.5_EB*(ONE_D%TMP(0)+ONE_D%TMP(1))
ONE_D%TMP_B  = 0.5_EB*(ONE_D%TMP(NWP)+ONE_D%TMP(NWP+1))

ONE_D%Q_CON_F = ONE_D%Q_CON_F - 0.5_EB*HTCF*DT_BC_SUB*ONE_D%TMP_F

! Clipping for excessively high or low temperatures

ONE_D%TMP_F  = MIN(TMPMAX,MAX(TMPMIN,ONE_D%TMP_F))
ONE_D%TMP_B  = MIN(TMPMAX,MAX(TMPMIN,ONE_D%TMP_B))

! Updated particle production
IF (SF%N_LPC > 0) THEN
   ONE_D%PART_MASS(1:SF%N_LPC) = ONE_D%PART_MASS(1:SF%N_LPC) + DT_BC_SUB * M_DOT_PART_S(1:SF%N_LPC)
   ONE_D%PART_ENTHALPY(1:SF%N_LPC) = ONE_D%PART_ENTHALPY(1:SF%N_LPC) + DT_BC_SUB * Q_DOT_PART_S(1:SF%N_LPC)
   ONE_D%T_MATL_PART = ONE_D%T_MATL_PART + DT_BC_SUB
   ONE_D%M_DOT_PART_ACTUAL = SUM(M_DOT_PART_S(1:SF%N_LPC))
ENDIF

! Determine if the iterations are done, otherwise return to the top

IF (T_BC_SUB>=DT_BC-TWO_EPSILON_EB) EXIT SUB_TIMESTEP_LOOP

ONE_D%N_SUBSTEPS = ONE_D%N_SUBSTEPS + 1

ENDDO SUB_TIMESTEP_LOOP

ONE_D%Q_CON_F = ONE_D%Q_CON_F / DT_BC
ONE_D%HEAT_TRANS_COEF = HTCF

! If any gas massflux or particle mass flux is non-zero or the surface temperature exceeds the ignition temperature,
! set the ignition time

IF (ONE_D%T_IGN > T) THEN
   IF (SUM(ONE_D%M_DOT_G_PP_ADJUST(1:N_TRACKED_SPECIES)) > 0._EB .OR. ONE_D%M_DOT_PART_ACTUAL > 0._EB ) ONE_D%T_IGN = T
   IF (ONE_D%TMP_F>=SF%TMP_IGN) ONE_D%T_IGN = T
ENDIF

! If the surface temperature is less than the extinction temperature, stop the burning

IF (SF%TMP_IGN<50000._EB .AND. ONE_D%TMP_F<SF%TMP_EXT .AND. ONE_D%T_IGN<T) ONE_D%T_IGN = HUGE(1._EB)

END SUBROUTINE SOLID_HEAT_TRANSFER_1D


!> \brief Calculate the solid phase reaction. Return heat and mass generation rates per unit volume.
!>
!> \param N_MATS Number of material components in the solid
!> \param MATL_INDEX (1:N_MATS) Indices of the material components from the master material list
!> \param SURF_INDEX Index of surface, used only for liquids
!> \param IIG I index of nearest gas phase cell
!> \param JJG J index of nearest gas phase cell
!> \param KKG K index of nearest gas phase cell
!> \param TMP_S Solid interior temperature (K)
!> \param TMP_F Solid surface temperature (K)
!> \param IOR Index of orientation of the surface with the liquid droplet, if appropropriate (0 for gas phase droplet)
!> \param RHO_DOT_OUT (1:N_MATS) Array of component reaction rates (kg/m3/s)
!> \param RHO_S (1:N_MATS) Array of component densities (kg/m3)
!> \param DEPTH Distance from surface (m)
!> \param DT_BC Time step used by the solid phase solver (s)
!> \param M_DOT_G_PPP_ADJUST (1:N_TRACKED_SPECIES) Adjusted mass generation rate per unit volume of the gas species
!> \param M_DOT_G_PPP_ACTUAL (1:N_TRACKED_SPECIES) Actual mass generation rate per unit volume of the gas species
!> \param M_DOT_S_PPP (1:N_MATS) Mass generation/depletion rate per unit volume of solid components (kg/m3/s)
!> \param Q_DOT_S_PPP Heat release rate per unit volume (W/m3)
!> \param Q_DOT_G_PPP Rate of energy required to bring gaseous pyrolyzate to the surrounding gas temperature (W/m3)
!> \param Q_DOT_O2_PPP Heat release rate per unit volume due to char oxidation in grid cell abutting surface (W/m3)
!> \param Q_DOT_PART Rate of enthalpy production of particles created in reactions (J/m3/s)
!> \param M_DOT_PART Rate of mass production of particles created in reactions (kg/m3/s)
!> \param T_BOIL_EFF Effective boiling temperature (K)
!> \param B_NUMBER B-number of liquid surface
!> \param SOLID_CELL_INDEX (OPTIONAL) Index of the interior solid cell
!> \param R_DROP (OPTIONAL) Radius of liquid droplet
!> \param LPU (OPTIONAL) x component of droplet velocity (m/s)
!> \param LPV (OPTIONAL) y component of droplet velocity (m/s)
!> \param LPW (OPTIONAL) z component of droplet velocity (m/s)

SUBROUTINE PYROLYSIS(N_MATS,MATL_INDEX,SURF_INDEX,IIG,JJG,KKG,TMP_S,TMP_F,IOR,RHO_DOT_OUT,RHO_S,DEPTH,DT_BC,&
                     M_DOT_G_PPP_ADJUST,M_DOT_G_PPP_ACTUAL,M_DOT_S_PPP,Q_DOT_S_PPP,Q_DOT_G_PPP,Q_DOT_O2_PPP,&
                     Q_DOT_PART,M_DOT_PART,T_BOIL_EFF,B_NUMBER,LAYER_INDEX,SOLID_CELL_INDEX,&
                     R_DROP,LPU,LPV,LPW)

USE PHYSICAL_FUNCTIONS, ONLY: GET_MASS_FRACTION,GET_VISCOSITY,GET_PARTICLE_ENTHALPY,&
                              GET_MASS_FRACTION_ALL,GET_EQUIL_DATA,GET_SENSIBLE_ENTHALPY,GET_Y_SURF,GET_FILM_PROPERTIES
USE MATH_FUNCTIONS, ONLY: INTERPOLATE1D_UNIFORM
USE TURBULENCE, ONLY: RAYLEIGH_HEAT_FLUX_MODEL,RAYLEIGH_MASS_FLUX_MODEL
INTEGER, INTENT(IN) :: N_MATS,SURF_INDEX,IIG,JJG,KKG,IOR,LAYER_INDEX
INTEGER, INTENT(IN), OPTIONAL :: SOLID_CELL_INDEX
REAL(EB), INTENT(OUT), DIMENSION(:,:) :: RHO_DOT_OUT(N_MATS)
REAL(EB), INTENT(IN) :: TMP_S,TMP_F,DT_BC,DEPTH
REAL(EB), INTENT(IN), OPTIONAL :: R_DROP,LPU,LPV,LPW
REAL(EB), DIMENSION(:) :: RHO_S(N_MATS),ZZ_GET(1:N_TRACKED_SPECIES),Y_ALL(1:N_SPECIES)
REAL(EB), DIMENSION(:), INTENT(OUT) :: M_DOT_G_PPP_ADJUST(N_TRACKED_SPECIES),M_DOT_G_PPP_ACTUAL(N_TRACKED_SPECIES)
REAL(EB), DIMENSION(:), INTENT(OUT) :: M_DOT_S_PPP(MAX_MATERIALS),Q_DOT_PART(MAX_LPC),M_DOT_PART(MAX_LPC)
REAL(EB), INTENT(OUT) :: Q_DOT_G_PPP,Q_DOT_O2_PPP,B_NUMBER
REAL(EB), INTENT(INOUT) :: T_BOIL_EFF
INTEGER, INTENT(IN), DIMENSION(:) :: MATL_INDEX(N_MATS)
INTEGER :: N,NN,NNN,J,NS,SMIX_INDEX(N_MATS),NWP,NP,NP2,ITMP
TYPE(MATERIAL_TYPE), POINTER :: ML
TYPE(SURFACE_TYPE), POINTER :: SF
REAL(EB) :: REACTION_RATE,Y_O2,X_O2,Q_DOT_S_PPP,MW(N_MATS),Y_GAS(N_MATS),Y_TMP(N_MATS),Y_SV(N_MATS),X_SV(N_MATS),X_L(N_MATS),&
            D_FILM,H_MASS,RE_L,SHERWOOD,MFLUX,MU_FILM,MU_AIR,SC_FILM,U_TANG,RDN,TMP_FILM,TMP_G,U2,V2,W2,VEL,&
            RHO_DOT,DR,R_S_0,R_S_1,H_R,H_R_B,H_S_B,H_S,LENGTH_SCALE,SUM_Y_GAS,SUM_Y_SV,&
            SUM_Y_SV_SMIX(N_TRACKED_SPECIES),X_L_SUM,RHO_DOT_EXTRA,MFLUX_MAX,RHO_FILM,CP_FILM,PR_FILM,K_FILM,EVAP_FILM_FAC
LOGICAL :: LIQUID(N_MATS),SPEC_ID_ALREADY_USED(N_MATS),DO_EVAPORATION

B_NUMBER = 0._EB
Q_DOT_S_PPP = 0._EB
Q_DOT_G_PPP = 0._EB
Q_DOT_O2_PPP = 0._EB
M_DOT_S_PPP = 0._EB
M_DOT_G_PPP_ADJUST = 0._EB
M_DOT_G_PPP_ACTUAL = 0._EB
M_DOT_PART = 0._EB
Q_DOT_PART = 0._EB
SF => SURFACE(SURF_INDEX)
RHO_DOT_OUT = 0._EB

! Determine if any liquids are present. If they are, determine if this is a the surface layer.

DO_EVAPORATION = .FALSE.
IF (ANY(MATERIAL(MATL_INDEX(:))%PYROLYSIS_MODEL==PYROLYSIS_LIQUID)) THEN
   IF (PRESENT(SOLID_CELL_INDEX)) THEN
      IF (SOLID_CELL_INDEX==1) DO_EVAPORATION = .TRUE.
   ENDIF
ENDIF

! If this is surface liquid layer, calculate the Spalding B number and other liquid-specific variables

IF_DO_EVAPORATION: IF (DO_EVAPORATION) THEN

   ! Calculate a sum needed to calculate the volume fraction of liquid components

   LIQUID  = .FALSE.
   X_L_SUM = 0._EB
   MATERIAL_LOOP_00: DO N=1,N_MATS
      ML => MATERIAL(MATL_INDEX(N))
      IF (ML%PYROLYSIS_MODEL/=PYROLYSIS_LIQUID) CYCLE MATERIAL_LOOP_00
      IF (RHO_S(N) < TWO_EPSILON_EB) CYCLE MATERIAL_LOOP_00
      LIQUID(N) = .TRUE.
      X_L_SUM = X_L_SUM + RHO_S(N)/ML%RHO_S
   ENDDO MATERIAL_LOOP_00

   IF (X_L_SUM < TWO_EPSILON_EB) RETURN

   SUM_Y_GAS = 0._EB
   SPEC_ID_ALREADY_USED = .FALSE.
   SMIX_INDEX = 0
   X_L = 0._EB
   X_SV = 0._EB

   MATERIAL_LOOP_0: DO N=1,N_MATS

      IF (.NOT.LIQUID(N)) CYCLE MATERIAL_LOOP_0
      ML => MATERIAL(MATL_INDEX(N))

      SMIX_INDEX(N) = MAXLOC(ML%NU_GAS(:,1),1)
      ZZ_GET(1:N_TRACKED_SPECIES) = MAX(0._EB,ZZ(IIG,JJG,KKG,1:N_TRACKED_SPECIES))

      IF (ML%MW<0._EB) THEN  ! No molecular weight specified; assume the liquid component evaporates into the defined gas species
         MW(N) = SPECIES_MIXTURE(SMIX_INDEX(N))%MW
      ELSE  ! the user has specified a molecular weight for the liquid component
         MW(N) = ML%MW
      ENDIF

      ! Determine the mass fraction of evaporated MATL N in the first gas phase grid cell

      IF (SPECIES_MIXTURE(SMIX_INDEX(N))%SINGLE_SPEC_INDEX > 0) THEN
         CALL GET_MASS_FRACTION_ALL(ZZ_GET,Y_ALL)
         Y_GAS(N) = Y_ALL(SPECIES_MIXTURE(SMIX_INDEX(N))%SINGLE_SPEC_INDEX)
         IF (SPECIES_MIXTURE(SMIX_INDEX(N))%CONDENSATION_SMIX_INDEX > 0) &
               Y_GAS(N) = Y_GAS(N) - ZZ_GET(SPECIES_MIXTURE(SMIX_INDEX(N))%CONDENSATION_SMIX_INDEX)
      ELSE
         Y_GAS(N) = ZZ_GET(SMIX_INDEX(N))
      ENDIF

      ! Determine volume fraction of MATL N in the liquid and then the surface vapor layer

      T_BOIL_EFF = ML%TMP_BOIL
      CALL GET_EQUIL_DATA(MW(N),TMP_F,PBAR(KKG,PRESSURE_ZONE(IIG,JJG,KKG)),H_R,H_R_B,T_BOIL_EFF,X_SV(N),ML%H_R(1,:))
      X_L(N)  = RHO_S(N)/(ML%RHO_S*X_L_SUM)  ! Volume fraction of MATL component N in the liquid
      X_SV(N) = X_L(N)*X_SV(N)               ! Volume fraction of MATL component N in the surface vapor based on Raoult's law

      ! Calculate sums to be used to compute B number
      IF (.NOT.SPEC_ID_ALREADY_USED(N)) SUM_Y_GAS = SUM_Y_GAS + Y_GAS(N)
      SPEC_ID_ALREADY_USED(N) = .TRUE.

   ENDDO MATERIAL_LOOP_0

   ! Convert mole fraction to mass fraction
   CALL GET_Y_SURF(N_MATS,ZZ_GET,X_SV,Y_SV,MW,SMIX_INDEX)

   ! Compute the Spalding B number

   SUM_Y_SV = SUM(Y_SV)
   SUM_Y_SV_SMIX = 0._EB
   MATERIAL_LOOP_1: DO N=1,N_MATS
      IF (.NOT.LIQUID(N)) CYCLE MATERIAL_LOOP_1
      SUM_Y_SV_SMIX(SMIX_INDEX(N)) = SUM_Y_SV_SMIX(SMIX_INDEX(N)) + Y_SV(N)
   ENDDO MATERIAL_LOOP_1

   IF (SUM_Y_SV<ALMOST_ONE) THEN
      B_NUMBER = MAX(0._EB,(SUM_Y_SV-SUM(Y_GAS))/(1._EB-SUM_Y_SV))
   ELSE
      B_NUMBER = 1.E6_EB  ! Fictitiously high B number intended to push mass flux to its upper limit
   ENDIF

   ! Compute an effective gas phase mass fraction, Y_GAS, corresponding to each liquid component, N

   Y_TMP = 0._EB
   MATERIAL_LOOP_2: DO N=1,N_MATS
      IF (.NOT.LIQUID(N)) CYCLE MATERIAL_LOOP_2
      IF (SUM_Y_SV_SMIX(SMIX_INDEX(N))>TWO_EPSILON_EB) Y_TMP(N) = Y_SV(N)*Y_GAS(N)/SUM_Y_SV_SMIX(SMIX_INDEX(N))
   ENDDO MATERIAL_LOOP_2
   Y_GAS = Y_TMP

   ! Get film properties

   SELECT CASE(SF%GEOMETRY)
      CASE DEFAULT; EVAP_FILM_FAC = PLATE_FILM_FAC
      CASE(SURF_SPHERICAL); EVAP_FILM_FAC = SPHERE_FILM_FAC
      CASE(SURF_CYLINDRICAL); EVAP_FILM_FAC = PLATE_FILM_FAC
      CASE(SURF_CARTESIAN); EVAP_FILM_FAC = PLATE_FILM_FAC
   END SELECT

   CALL GET_FILM_PROPERTIES(N_MATS,EVAP_FILM_FAC,Y_SV,Y_GAS,SMIX_INDEX,TMP_F,TMP(IIG,JJG,KKG),ZZ_GET,&
                           PBAR(KKG,PRESSURE_ZONE(IIG,JJG,KKG)),TMP_FILM,MU_FILM,K_FILM,CP_FILM,D_FILM,&
                           RHO_FILM,PR_FILM,SC_FILM)

   ! Compute mass transfer coefficient

   H_MASS_IF: IF (SF%HM_FIXED>=0._EB) THEN

      H_MASS = SF%HM_FIXED

   ELSEIF (SIM_MODE==DNS_MODE) THEN H_MASS_IF

      SELECT CASE(ABS(IOR))
         CASE(1); H_MASS = 2._EB*D_FILM*RDX(IIG)
         CASE(2); H_MASS = 2._EB*D_FILM*RDY(JJG)
         CASE(3); H_MASS = 2._EB*D_FILM*RDZ(KKG)
      END SELECT

   ELSE H_MASS_IF

      IF (PRESENT(LPU) .AND. PRESENT(LPV) .AND. PRESENT(LPW)) THEN
         U2 = 0.5_EB*(U(IIG,JJG,KKG)+U(IIG-1,JJG,KKG))
         V2 = 0.5_EB*(V(IIG,JJG,KKG)+V(IIG,JJG-1,KKG))
         W2 = 0.5_EB*(W(IIG,JJG,KKG)+W(IIG,JJG,KKG-1))
         VEL = SQRT((U2-LPU)**2+(V2-LPV)**2+(W2-LPW)**2)
      ELSE
         VEL = SQRT(2._EB*KRES(IIG,JJG,KKG))
      ENDIF
      CALL GET_VISCOSITY(ZZ_GET,MU_FILM,TMP_FILM)
      IF (PRESENT(R_DROP)) THEN
         LENGTH_SCALE = 2._EB*R_DROP
      ELSE
         LENGTH_SCALE = SF%CONV_LENGTH
      ENDIF
      RE_L     = RHO_FILM*VEL*LENGTH_SCALE/MU_FILM
      SELECT CASE(SF%GEOMETRY)
         CASE DEFAULT         ; SHERWOOD = 0.037_EB*SC_FILM**ONTH*RE_L**0.8_EB
         CASE(SURF_SPHERICAL) ; SHERWOOD = 2._EB + 0.6_EB*SC_FILM**ONTH*SQRT(RE_L)
      END SELECT
      H_MASS   = SHERWOOD*D_FILM/LENGTH_SCALE
   ENDIF H_MASS_IF

ENDIF IF_DO_EVAPORATION


! Calculate reaction rates for liquids, solids and vegetation

MATERIAL_LOOP: DO N=1,N_MATS  ! Loop over all materials in the cell (alpha subscript)

   IF (RHO_S(N) < TWO_EPSILON_EB) CYCLE MATERIAL_LOOP  ! If component alpha density is zero, go on to the next material.
   ML => MATERIAL(MATL_INDEX(N))

   REACTION_LOOP: DO J=1,ML%N_REACTIONS  ! Loop over the reactions (beta subscript)

      SELECT CASE (ML%PYROLYSIS_MODEL)

         CASE (PYROLYSIS_LIQUID)

            ! Limit the burning rate to (200 kW/m2) / h_g

             MFLUX_MAX = 200.E3_EB/ML%H_R(J,INT(TMP_F))

            ! Calculate the mass flux of liquid component N at the surface if this is a surface cell.

            IF (DO_EVAPORATION) THEN
               IF (B_NUMBER>TWO_EPSILON_EB) THEN
                  MFLUX = MAX(0._EB,MIN(MFLUX_MAX,H_MASS*RHO_FILM*LOG(1._EB+B_NUMBER)*(Y_SV(N) + (Y_SV(N)-Y_GAS(N))/B_NUMBER)))
               ELSE
                  MFLUX = 0._EB
               ENDIF
            ELSE
               MFLUX = 0._EB
            ENDIF

            IF (DX_S(SOLID_CELL_INDEX)>TWO_EPSILON_EB) THEN

               ! If the liquid temperature (TMP_S) is greater than the boiling temperature of the current liquid component
               ! (ML%TMP_BOIL), calculate the additional mass loss rate of this component (RHO_DOT_EXTRA) necessary to bring
               ! the liquid temperature back to the boiling temperature.

               RHO_DOT_EXTRA = 0._EB
               IF (TMP_S>ML%TMP_BOIL) THEN
                  ITMP = MIN(I_MAX_TEMP,INT(TMP_S))
                  H_S = ML%H(ITMP) + (TMP_S-REAL(ITMP,EB))*(ML%H(ITMP+1)-ML%H(ITMP))
                  ITMP = INT(ML%TMP_BOIL)
                  H_S = H_S - (ML%H(ITMP) + (ML%TMP_BOIL-REAL(ITMP,EB))*(ML%H(ITMP+1)-ML%H(ITMP)))
                  H_S = H_S * RHO_S(N)
                  H_R = ML%H_R(1,NINT(ML%TMP_BOIL))
                  RHO_DOT_EXTRA = H_S/(H_R*DT_BC)  ! kg/m3/s
               ENDIF

               ! Calculate the mass loss rate per unit volume of this liquid component (RHO_DOT)

               SELECT CASE(SF%GEOMETRY)
                  CASE DEFAULT
                     MFLUX = MIN(MFLUX_MAX,MFLUX + RHO_DOT_EXTRA*DX_S(SOLID_CELL_INDEX))
                     RHO_DOT = MIN(MFLUX/DX_S(SOLID_CELL_INDEX),ML%RHO_S/DT_BC)  ! kg/m3/s
                  CASE(SURF_SPHERICAL)
                     NWP = SUM(ONE_D%N_LAYER_CELLS(1:SF%N_LAYERS))
                     R_S_0 = SF%INNER_RADIUS + ONE_D%X(NWP) - ONE_D%X(0)
                     R_S_1 = SF%INNER_RADIUS + ONE_D%X(NWP) - ONE_D%X(1)
                     DR = (R_S_0**3-R_S_1**3)/(3._EB*R_S_0**2)
                     MFLUX = MIN(MFLUX_MAX,MFLUX + RHO_DOT_EXTRA*DR)
                     RHO_DOT = MIN(MFLUX/DR,ML%RHO_S/DT_BC)
               END SELECT

            ENDIF

            ! handle case with 3D pyrolysis

            IF (SF%HT3D) THEN
               SELECT CASE(IOR)
                  CASE( 1); RDN = RDX(IIG-1)
                  CASE(-1); RDN = RDX(IIG+1)
                  CASE( 2); RDN = RDY(JJG-1)
                  CASE(-2); RDN = RDY(JJG+1)
                  CASE( 3); RDN = RDZ(KKG-1)
                  CASE(-3); RDN = RDZ(KKG+1)
               END SELECT
               RHO_DOT = MIN(MFLUX*RDN,ML%RHO_S/DT_BC)
            ENDIF

         CASE (PYROLYSIS_SOLID)

            ! Reaction rate in 1/s (Tech Guide: r_alpha_beta)

            REACTION_RATE = ML%A(J)*(RHO_S(N))**ML%N_S(J)*EXP(-ML%E(J)/(R0*TMP_S))

            ! power term

            IF (ABS(ML%N_T(J))>=TWO_EPSILON_EB) REACTION_RATE = REACTION_RATE * TMP_S**ML%N_T(J)

            ! Oxidation reaction?

            IF ( (ML%N_O2(J)>0._EB) .AND. (O2_INDEX > 0)) THEN
               ! Get oxygen mass fraction
               ZZ_GET(1:N_TRACKED_SPECIES) = MAX(0._EB,ZZ(IIG,JJG,KKG,1:N_TRACKED_SPECIES))
               CALL GET_MASS_FRACTION(ZZ_GET,O2_INDEX,Y_O2)
               ! Calculate oxygen volume fraction in the gas cell
               X_O2 = SPECIES(O2_INDEX)%RCON*Y_O2/RSUM(IIG,JJG,KKG)
               ! Calculate oxygen concentration inside the material, assuming decay function
               X_O2 = X_O2 * EXP(-DEPTH/(TWO_EPSILON_EB+ML%GAS_DIFFUSION_DEPTH(J)))
               REACTION_RATE = REACTION_RATE * X_O2**ML%N_O2(J)
            ENDIF
            REACTION_RATE = MIN(REACTION_RATE,ML%MAX_REACTION_RATE(J))  ! User-specified limit
            RHO_DOT = MIN(REACTION_RATE,RHO_S(N)/DT_BC)  ! Tech Guide: rho_s(0)*r_alpha,beta kg/m3/s

         CASE (PYROLYSIS_VEGETATION)

            ! Tech Guide: r_alpha,beta (1/s)
            REACTION_RATE = ML%A(J)*(RHO_S(N))**ML%N_S(J)*EXP(-ML%E(J)/(R0*TMP_S))
            ! power term
            IF (ABS(ML%N_T(J))>=TWO_EPSILON_EB) REACTION_RATE = REACTION_RATE * TMP_S**ML%N_T(J)
            ! Oxidation reaction?
            IF ( (ML%NU_O2_CHAR(J)>0._EB) .AND. (O2_INDEX > 0)) THEN
               ! Get oxygen mass fraction
               ZZ_GET(1:N_TRACKED_SPECIES) = MAX(0._EB,ZZ(IIG,JJG,KKG,1:N_TRACKED_SPECIES))
               CALL GET_MASS_FRACTION(ZZ_GET,O2_INDEX,Y_O2)
               CALL GET_VISCOSITY(ZZ_GET,MU_AIR,TMP(IIG,JJG,KKG))
               U_TANG = SQRT(2._EB*KRES(IIG,JJG,KKG))
               IF (PRESENT(R_DROP)) THEN
                  LENGTH_SCALE = 2._EB*R_DROP
               ELSE
                  LENGTH_SCALE = SF%CONV_LENGTH
               ENDIF
               RE_L   = RHO(IIG,JJG,KKG)*U_TANG*LENGTH_SCALE/MU_AIR
               REACTION_RATE = REACTION_RATE * RHO(IIG,JJG,KKG)*Y_O2*(4._EB/LENGTH_SCALE) * &
                               (1._EB+ML%BETA_CHAR(J)*SQRT(RE_L))/(ML%NU_O2_CHAR(J))
            ENDIF
            REACTION_RATE = MIN(REACTION_RATE,ML%MAX_REACTION_RATE(J))  ! User-specified limit
            RHO_DOT = MIN(REACTION_RATE , RHO_S(N)/DT_BC)  ! Tech Guide: rho_s(0)*r_alpha,beta kg/m3/s

      END SELECT

      ! Optional limiting of fuel burnout time

      IF (SF%MINIMUM_BURNOUT_TIME<1.E5_EB) THEN
         RHO_DOT = MIN(RHO_DOT,SF%LAYER_DENSITY(LAYER_INDEX)/SF%MINIMUM_BURNOUT_TIME)
      ENDIF

      ! Compute new component density, RHO_S(N)

      RHO_DOT_OUT(N) = RHO_DOT_OUT(N) + RHO_DOT  ! rho_s,alpha_new = rho_s,alpha_old-dt*rho_s(0)*r_alpha,beta
      DO NN=1,ML%N_RESIDUE(J) ! Get residue production (alpha' represents the other materials)
         NNN = FINDLOC(MATL_INDEX,ML%RESIDUE_MATL_INDEX(NN,J),1)
         RHO_DOT_OUT(NNN) = RHO_DOT_OUT(NNN) - ML%NU_RESIDUE(NN,J)*RHO_DOT
         M_DOT_S_PPP(NNN) = M_DOT_S_PPP(NNN) + ML%NU_RESIDUE(NN,J)*RHO_DOT ! (m_dot_alpha')'''
      ENDDO

      ! Optional variable heat of reaction

      ITMP = MIN(I_MAX_TEMP,NINT(TMP_S))
      H_R = ML%H_R(J,ITMP)

      ! Calculate various energy and mass source terms

      Q_DOT_S_PPP    = Q_DOT_S_PPP - RHO_DOT*H_R  ! Tech Guide: q_dot_s'''
      M_DOT_S_PPP(N) = M_DOT_S_PPP(N) - RHO_DOT   ! m_dot_alpha''' = -rho_s(0) * sum_beta r_alpha,beta
      TMP_G = TMP(IIG,JJG,KKG)
      DO NS=1,N_TRACKED_SPECIES  ! Tech Guide: m_dot_gamma'''
         M_DOT_G_PPP_ADJUST(NS) = M_DOT_G_PPP_ADJUST(NS) + ML%ADJUST_BURN_RATE(NS,J)*ML%NU_GAS(NS,J)*RHO_DOT
         M_DOT_G_PPP_ACTUAL(NS) = M_DOT_G_PPP_ACTUAL(NS) + ML%NU_GAS(NS,J)*RHO_DOT
         ZZ_GET=0._EB
         ZZ_GET(NS)=1._EB
         CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S_B,TMP_S)
         CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP_G)
         IF (ML%NU_GAS(NS,J) > 0._EB) THEN
            Q_DOT_G_PPP = Q_DOT_G_PPP + ML%ADJUST_BURN_RATE(NS,J)*ML%NU_GAS(NS,J)*RHO_DOT*(H_S-H_S_B)
         ELSE
            Q_DOT_S_PPP = Q_DOT_S_PPP - ML%ADJUST_BURN_RATE(NS,J)*ML%NU_GAS(NS,J)*RHO_DOT*(H_S-H_S_B)
         ENDIF
      ENDDO

      IF (ANY(ML%NU_LPC(:,J)>0._EB)) THEN
         DO NP=1,N_LAGRANGIAN_CLASSES
            IF (ML%NU_LPC(NP,J)<=0._EB) CYCLE
            DO NP2=1,SF%N_LPC
               IF (SF%MATL_PART_INDEX(NP2)==NP) THEN
                  M_DOT_PART(NP2)=ML%NU_LPC(NP,J)*RHO_DOT
                  Q_DOT_PART(NP2)=GET_PARTICLE_ENTHALPY(NP,TMP_S)*M_DOT_PART(NP2)
               ENDIF
            ENDDO
         ENDDO
      ENDIF

      ! If there is char oxidation, save the HRR per unit volume generated

      IF (ML%NU_O2_CHAR(J)>0._EB) THEN
         IF (SIMPLE_CHEMISTRY) THEN
            Q_DOT_O2_PPP = Q_DOT_O2_PPP + ABS(M_DOT_G_PPP_ACTUAL(REACTION(1)%AIR_SMIX_INDEX)*Y_O2_INFTY*H_R/ML%NU_O2_CHAR(J))
         ELSE
            Q_DOT_O2_PPP = Q_DOT_O2_PPP + ABS(M_DOT_G_PPP_ACTUAL(O2_INDEX)*H_R/ML%NU_O2_CHAR(J))
         ENDIF
      ENDIF

   ENDDO REACTION_LOOP

ENDDO MATERIAL_LOOP

END SUBROUTINE PYROLYSIS


!> \brief Compute the convective heat transfer coefficient

REAL(EB) FUNCTION HEAT_TRANSFER_COEFFICIENT(DELTA_TMP,H_FIXED,SURF_INDEX_IN,WALL_INDEX_IN,CFACE_INDEX_IN,PARTICLE_INDEX_IN)

USE TURBULENCE, ONLY: LOGLAW_HEAT_FLUX_MODEL,NATURAL_CONVECTION_MODEL,FORCED_CONVECTION_MODEL,RAYLEIGH_HEAT_FLUX_MODEL
USE PHYSICAL_FUNCTIONS, ONLY: GET_CONDUCTIVITY,GET_VISCOSITY,GET_SPECIFIC_HEAT
REAL(EB), INTENT(IN) :: DELTA_TMP,H_FIXED
INTEGER, INTENT(IN) :: SURF_INDEX_IN
INTEGER, INTENT(IN), OPTIONAL :: WALL_INDEX_IN,PARTICLE_INDEX_IN,CFACE_INDEX_IN
INTEGER  :: IIG,JJG,KKG,IC2,SURF_GEOMETRY
REAL(EB) :: RE,H_NATURAL,H_FORCED,FRICTION_VELOCITY=0._EB,YPLUS=0._EB,ZSTAR,DN,TMP_FILM,MU_G,K_G,CP_G,&
            TMP_G,R_DROP,TMP_2,H_1,H_2,GAMMA,DTDX_W,RHO_G,ZZ_G(1:N_TRACKED_SPECIES),CONV_LENGTH,GR,RA,NUSSELT_FORCED,NUSSELT_FREE
TYPE(SURFACE_TYPE), POINTER :: SFX
TYPE(WALL_TYPE), POINTER :: WCX
TYPE(CFACE_TYPE), POINTER :: CFAX
TYPE(LAGRANGIAN_PARTICLE_TYPE), POINTER :: LPX
TYPE(BOUNDARY_ONE_D_TYPE), POINTER :: ONE_DX
TYPE(BOUNDARY_PROPS_TYPE), POINTER :: BPX
TYPE(BOUNDARY_COORD_TYPE), POINTER :: BCX

SFX => SURFACE(SURF_INDEX_IN)
CONV_LENGTH = SFX%CONV_LENGTH

! If the user wants a specified HTC, set it and return

IF (H_FIXED >= 0._EB) THEN
   HEAT_TRANSFER_COEFFICIENT = H_FIXED
   RETURN
ENDIF

! Determine if this is a particle or wall cell

IF (PRESENT(PARTICLE_INDEX_IN)) THEN
   LPX => LAGRANGIAN_PARTICLE(PARTICLE_INDEX_IN)
   ONE_DX => BOUNDARY_ONE_D(LPX%OD_INDEX)
   BCX => BOUNDARY_COORD(LPX%BC_INDEX)
   DN = SFX%CONV_LENGTH
   R_DROP = SUM(ONE_DX%LAYER_THICKNESS(1:SFX%N_LAYERS))
   IF (R_DROP>TWO_EPSILON_EB) CONV_LENGTH = 2._EB*R_DROP
   TMP_G  = TMP(BCX%IIG,BCX%JJG,BCX%KKG)
   RHO_G  = RHO(BCX%IIG,BCX%JJG,BCX%KKG)
   ZZ_G(1:N_TRACKED_SPECIES) = ZZ(BCX%IIG,BCX%JJG,BCX%KKG,1:N_TRACKED_SPECIES)
ELSEIF (PRESENT(WALL_INDEX_IN)) THEN
   WCX   => WALL(WALL_INDEX_IN)
   ONE_DX => BOUNDARY_ONE_D(WCX%OD_INDEX)
   BPX => BOUNDARY_PROPS(WCX%BP_INDEX)
   BCX => BOUNDARY_COORD(WCX%BC_INDEX)
   DN = 1._EB/ONE_DX%RDN
   TMP_G  = TMP(BCX%IIG,BCX%JJG,BCX%KKG)
   RHO_G  = RHO(BCX%IIG,BCX%JJG,BCX%KKG)
   ZZ_G(1:N_TRACKED_SPECIES) = ZZ(BCX%IIG,BCX%JJG,BCX%KKG,1:N_TRACKED_SPECIES)
ELSEIF (PRESENT(CFACE_INDEX_IN)) THEN
   CFAX => CFACE(CFACE_INDEX_IN)
   ONE_DX => BOUNDARY_ONE_D(CFAX%OD_INDEX)
   BPX => BOUNDARY_PROPS(CFAX%BP_INDEX)
   BCX => BOUNDARY_COORD(CFAX%BC_INDEX)
   DN = 1._EB/ONE_DX%RDN
   TMP_G  = CFA%TMP_G
   RHO_G  = CFA%RHO_G
   ZZ_G   = CFA%ZZ_G
ELSE
   HEAT_TRANSFER_COEFFICIENT = 1.31_EB*ABS(DELTA_TMP)**ONTH  ! Natural convection for vertical plane
   RETURN
ENDIF

! If this is a DNS calculation at a solid wall, set HTC and return.

IF ( (SIM_MODE==DNS_MODE .OR. SOLID_PHASE_ONLY) .AND. (PRESENT(WALL_INDEX_IN) .OR. PRESENT(CFACE_INDEX_IN)) ) THEN

   IF (ABS(DELTA_TMP)<TWO_EPSILON_EB) THEN
      HEAT_TRANSFER_COEFFICIENT = 2._EB * ONE_DX%K_G * ONE_DX%RDN
      RETURN
   ENDIF

   IF (PRESENT(WALL_INDEX_IN)) THEN
      ! O(dx^2) approximation to wall-normal temperature gradient
      IIG=BCX%IIG
      JJG=BCX%JJG
      KKG=BCX%KKG
      SELECT CASE(BCX%IOR)
         CASE( 1); IC2=CELL_INDEX(IIG+1,JJG,KKG)
         CASE(-1); IC2=CELL_INDEX(IIG-1,JJG,KKG)
         CASE( 2); IC2=CELL_INDEX(IIG,JJG+1,KKG)
         CASE(-2); IC2=CELL_INDEX(IIG,JJG-1,KKG)
         CASE( 3); IC2=CELL_INDEX(IIG,JJG,KKG+1)
         CASE(-3); IC2=CELL_INDEX(IIG,JJG,KKG-1)
      END SELECT
      IF (SOLID(IC2) .OR. EXTERIOR(IC2)) THEN
         HEAT_TRANSFER_COEFFICIENT = 2._EB * ONE_DX%K_G * ONE_DX%RDN
         RETURN
      ENDIF
      SELECT CASE(BCX%IOR)
         CASE( 1)
            TMP_2 = TMP(IIG+1,JJG,KKG)
            H_1   = 0.5_EB*DX(IIG)
            H_2   = DX(IIG) + 0.5_EB*DX(IIG+1)
         CASE(-1)
            TMP_2=TMP(IIG-1,JJG,KKG)
            H_1   = 0.5_EB*DX(IIG)
            H_2   = DX(IIG) + 0.5_EB*DX(IIG-1)
         CASE( 2)
            TMP_2=TMP(IIG,JJG+1,KKG)
            H_1   = 0.5_EB*DY(JJG)
            H_2   = DY(JJG) + 0.5_EB*DY(JJG+1)
         CASE(-2)
            TMP_2=TMP(IIG,JJG-1,KKG)
            H_1   = 0.5_EB*DY(JJG)
            H_2   = DY(JJG) + 0.5_EB*DY(JJG-1)
         CASE( 3)
            TMP_2=TMP(IIG,JJG,KKG+1)
            H_1   = 0.5_EB*DZ(KKG)
            H_2   = DZ(KKG) + 0.5_EB*DZ(KKG+1)
         CASE(-3)
            TMP_2=TMP(IIG,JJG,KKG-1)
            H_1   = 0.5_EB*DZ(KKG)
            H_2   = DZ(KKG) + 0.5_EB*DZ(KKG-1)
      END SELECT
      GAMMA = (H_1/H_2)**2
      DTDX_W = ( GAMMA*TMP_2 - TMP_G + (1-GAMMA)*ONE_DX%TMP_F ) / ( GAMMA*H_2 - H_1 )
      HEAT_TRANSFER_COEFFICIENT = ONE_DX%K_G * DTDX_W / DELTA_TMP
   ELSEIF (PRESENT(CFACE_INDEX_IN)) THEN
      HEAT_TRANSFER_COEFFICIENT = 2._EB * ONE_DX%K_G * ONE_DX%RDN
   ENDIF
   RETURN
ENDIF

! Calculate HEAT_TRANSFER_COEFFICIENT

TMP_FILM = 0.5_EB*(TMP_G+ONE_DX%TMP_F)
CALL GET_VISCOSITY(ZZ_G,MU_G,TMP_FILM)
CALL GET_CONDUCTIVITY(ZZ_G,K_G,TMP_FILM)

HTC_MODEL_SELECT: SELECT CASE(SFX%HEAT_TRANSFER_MODEL)
   CASE(DEFAULT_HTC_MODEL)
      RE = RHO_G*ONE_DX%U_TANG*CONV_LENGTH/MU_G
      GR = GRAV*ABS(DELTA_TMP)*CONV_LENGTH**3*(RHO_G/MU_G)**2/TMP_FILM
      IF (SFX%BOUNDARY_FUEL_MODEL) THEN
         SURF_GEOMETRY = SURF_CYLINDRICAL
      ELSE
         SURF_GEOMETRY = SFX%GEOMETRY
      ENDIF
      ! Check if custom Nusselt correlation is defined
      IF (ANY((/SFX%NUSSELT_C0,SFX%NUSSELT_C1,SFX%NUSSELT_C2,SFX%NUSSELT_M/)>0._EB)) THEN 
         CALL FORCED_CONVECTION_MODEL(NUSSELT_FORCED,RE,PR_ONTH,SURF_GEOMETRY,&
            SFX%NUSSELT_C0,SFX%NUSSELT_C1,SFX%NUSSELT_C2,SFX%NUSSELT_M)
         
      ELSE
         CALL FORCED_CONVECTION_MODEL(NUSSELT_FORCED,RE,PR_ONTH,SURF_GEOMETRY)
      ENDIF
      RA = GR*PR_AIR
      CALL NATURAL_CONVECTION_MODEL(NUSSELT_FREE,RA,SURF_INDEX_IN,SFX%GEOMETRY,BCX%IOR)
      HEAT_TRANSFER_COEFFICIENT = MAX(NUSSELT_FORCED,NUSSELT_FREE,2._EB*CONV_LENGTH/DN)*K_G/CONV_LENGTH
   CASE(LOGLAW_HTC_MODEL)
      CALL GET_SPECIFIC_HEAT(ZZ_G,CP_G,TMP_FILM)
      FRICTION_VELOCITY = BPX%U_TAU
      YPLUS = BPX%Y_PLUS
      CALL LOGLAW_HEAT_FLUX_MODEL(H_FORCED,YPLUS,FRICTION_VELOCITY,K_G,RHO_G,CP_G,MU_G)
      HEAT_TRANSFER_COEFFICIENT = H_FORCED
   CASE(RAYLEIGH_HTC_MODEL)
      CALL GET_SPECIFIC_HEAT(ZZ_G,CP_G,TMP_FILM)
      CALL RAYLEIGH_HEAT_FLUX_MODEL(H_NATURAL,ZSTAR,DN,ONE_DX%TMP_F,TMP_G,K_G,RHO_G,CP_G,MU_G)
      IF (PRESENT(WALL_INDEX_IN) .OR. PRESENT(CFACE_INDEX_IN)) BPX%Z_STAR = ZSTAR
      HEAT_TRANSFER_COEFFICIENT = H_NATURAL
END SELECT HTC_MODEL_SELECT

END FUNCTION HEAT_TRANSFER_COEFFICIENT


SUBROUTINE TGA_ANALYSIS

! This routine performs a numerical TGA (thermo-gravimetric analysis) at the start of the simulation

USE PHYSICAL_FUNCTIONS, ONLY: SURFACE_DENSITY
USE COMP_FUNCTIONS, ONLY: SHUTDOWN
REAL(EB) :: DT_TGA=0.01_EB,T_TGA,SURF_DEN_0,HRR
REAL(EB), ALLOCATABLE, DIMENSION(:) :: SURF_DEN
INTEGER :: N_TGA,I,IW,IP,N
CHARACTER(80) :: MESSAGE,TCFORM
TYPE(SURFACE_TYPE), POINTER :: SF

CALL POINT_TO_MESH(1)

SF => SURFACE(TGA_SURF_INDEX)
ALLOCATE(SURF_DEN(0:SF%N_MATL))
RADIATION = .FALSE.
TGA_HEATING_RATE = TGA_HEATING_RATE/60._EB  ! K/min --> K/s
TGA_FINAL_TEMPERATURE = TGA_FINAL_TEMPERATURE + TMPM  ! C --> K
I_RAMP_AGT = 0
N_TGA = NINT((TGA_FINAL_TEMPERATURE-TMPA)/(TGA_HEATING_RATE*DT_TGA))
T_TGA = 0._EB

IF (TGA_WALL_INDEX>0) THEN
   IW = TGA_WALL_INDEX
   WC => WALL(IW)
   ONE_D => BOUNDARY_ONE_D(WC%OD_INDEX)
ELSEIF (TGA_PARTICLE_INDEX>0) THEN
   IP = TGA_PARTICLE_INDEX
   LP => LAGRANGIAN_PARTICLE(IP)
   ONE_D => BOUNDARY_ONE_D(LP%OD_INDEX)
ELSE
   WRITE(MESSAGE,'(A)') 'ERROR: No wall or particle to which to apply the TGA analysis'
   CALL SHUTDOWN(MESSAGE) ; RETURN
ENDIF

OPEN (LU_TGA,FILE=FN_TGA,FORM='FORMATTED',STATUS='REPLACE')
WRITE(TCFORM,'(A,I3.3,A,I3.3,A)') "(A,",SF%N_MATL+1,"(A,',')",SF%N_MATL+1,"(A,','),A)"
WRITE(LU_TGA,TCFORM) 's,C,',('g/g',N=1,SF%N_MATL+1),('1/s',N=1,SF%N_MATL+1),'W/g,W/g'
WRITE(LU_TGA,TCFORM) 'Time,Temp,','Total Mass',(TRIM(MATERIAL(SF%MATL_INDEX(N))%ID)//' Mass',N=1,SF%N_MATL),'Total MLR',&
                     (TRIM(MATERIAL(SF%MATL_INDEX(N))%ID)//' MLR',N=1,SF%N_MATL),'MCC,DSC'

SURF_DEN_0 = SF%SURFACE_DENSITY
WRITE(TCFORM,'(A,I3.3,5A)') "(",2*SF%N_MATL+5,"(",TRIM(FMT_R),",','),",TRIM(FMT_R),")"

DO I=1,N_TGA
   IF (ONE_D%LAYER_THICKNESS(1)<TWO_EPSILON_EB) EXIT
   T_TGA = I*DT_TGA
   ASSUMED_GAS_TEMPERATURE = TMPA + TGA_HEATING_RATE*T_TGA
   IF (TGA_WALL_INDEX>0) THEN
      CALL SOLID_HEAT_TRANSFER_1D(1,T_TGA,DT_TGA,WALL_INDEX=IW)
   ELSE
      CALL SOLID_HEAT_TRANSFER_1D(1,T_TGA,DT_TGA,PARTICLE_INDEX=IP)
   ENDIF
   IF (I==1 .OR. MOD(I,NINT(1._EB/(TGA_HEATING_RATE*DT_TGA)))==0) THEN
      IF (TGA_WALL_INDEX>0) THEN
         SURF_DEN(0) = SURFACE_DENSITY(1,0,WALL_INDEX=IW)
         DO N=1,SF%N_MATL
            SURF_DEN(N) = SURFACE_DENSITY(1,0,WALL_INDEX=IW,MATL_INDEX=N)
         ENDDO
      ELSE
         SURF_DEN(0) = SURFACE_DENSITY(1,0,LAGRANGIAN_PARTICLE_INDEX=IP)
         DO N=1,SF%N_MATL
            SURF_DEN(N) = SURFACE_DENSITY(1,0,LAGRANGIAN_PARTICLE_INDEX=IP,MATL_INDEX=N)
         ENDDO
      ENDIF
      IF (N_REACTIONS>0) THEN
         HRR = ONE_D%M_DOT_G_PP_ADJUST(REACTION(1)%FUEL_SMIX_INDEX)*0.001*REACTION(1)%HEAT_OF_COMBUSTION/&
                                                                                    (ONE_D%AREA_ADJUST*SURF_DEN_0)
      ELSE
         HRR = 0._EB
      ENDIF
      WRITE(LU_TGA,TCFORM) REAL(T_TGA,FB), REAL(ONE_D%TMP_F-TMPM,FB), (REAL(SURF_DEN(N)/SURF_DEN_0,FB),N=0,SF%N_MATL), &
                           REAL(-SUM(ONE_D%M_DOT_S_PP(1:SF%N_MATL))/SURF_DEN_0,FB), &
                           (REAL(-ONE_D%M_DOT_S_PP(N)/SURF_DEN_0,FB),N=1,SF%N_MATL), &
                           REAL(HRR,FB), REAL(ONE_D%HEAT_TRANS_COEF*(ASSUMED_GAS_TEMPERATURE-ONE_D%TMP_F)*0.001_EB/SURF_DEN_0,FB)
   ENDIF
ENDDO

CLOSE(LU_TGA)
DEALLOCATE(SURF_DEN)

END SUBROUTINE TGA_ANALYSIS

END MODULE WALL_ROUTINES
