!% Catchment cutting
!% input: List of station id, easting, northing and reference area
!% river file with each river branch having a unique id (see headwater_run.m)
!%   used to find candidate starting points
!% sinkfilled dem - with no flat areas used
!%   used to walk upstream to find all in catchment cells
!%
!% output series of grids representing the in catchment area,
!% each cell contains the flow length to outlet in m (same unit of cellsize/dx)
!% - expanded search if no decent matches
!%
!% Toby Dunne
!% Apr 2016
program catch_cut
    use dta_utility
    use dta_catch_cut
    use dta_riv_tree_node
    implicit none

    integer, parameter :: max_candidate = 150

    character(1024) in_dem_file

    character(1024) in_point_file

    character(1024) in_river_file

    character(1024) ref_catch_dir

    character(1024) tmp_char
    character(1024) result_file
    character(1024) candidate_file

    ! point list from file (to resume)
    double precision, allocatable, dimension(:,:) :: point_list_resume

    type(time_type) :: start_time, end_time, run_start_time, last_print_time
    integer ioerr

    CHARACTER(len=1024) :: arg

    double precision, allocatable, dimension(:,:) :: riv_grid
    logical, allocatable, dimension(:,:) :: riv_mask_grid
    double precision, allocatable, dimension(:,:) :: dem_grid

    integer(1), allocatable :: flow_dir_grid (:,:)
    integer, allocatable :: flow_dir_grid_int (:,:)
    double precision, allocatable :: slope_grid (:,:)

    integer catchment_id
    double precision :: ref_area_km2

    integer point_data_col_id
    integer point_data_col_x
    integer point_data_col_y
    integer point_data_col_ref_area ! used when reading catchment list

    double precision, allocatable, dimension(:,:) :: point_data

    integer i, j

    integer :: ncols, nrows, riv_ncols, riv_nrows
    double precision :: xllcorner, yllcorner, cellsize, riv_xllcorner, riv_yllcorner, riv_cellsize
    double precision :: double_nodata

    integer row, col
    integer starty, startx
    integer initial_radiusM, max_radiusM
    integer search_radius_cells_done
    integer search_radius_cells

    !% 1 = 1, 2 = x, 3 = y, 4 = processed
    integer candidates(max_candidate,4)
    double precision candidates_area(max_candidate)
    double precision candidates_dist(max_candidate)
    integer candidates_out_of_bounds(max_candidate)
    integer candidate_count

    double precision candidate_min_score
    double precision candidate_score_threshold

    double precision candidate_result_score(max_candidate)

    integer candidate_best
    logical is_complete
    character(len=30) stop_reason
    integer best_candidate_out_of_bounds
    double precision best_dist

    integer x, y

    logical, allocatable, dimension(:,:) :: mask_grid

    ! reference mask for checking
    integer, allocatable, dimension(:,:) :: reference_mask_grid
    logical, allocatable, dimension(:,:) :: reference_mask_logical_grid
    integer :: ref_nrows, ref_ncols, ref_nodata
    double precision :: ref_xllcorner, ref_yllcorner, ref_cellsize

    integer :: miny, maxy, minx, maxx
    integer :: area_count
    double precision :: calc_area_m2
    double precision :: calc_area_km2
    double precision :: outlet_x_east, outlet_y_north
    double precision :: score

    integer :: intersect_count, out_count
    logical :: input_is_valid
    logical :: write_catchment_mask
    integer :: task_count, task_progress
    type(point_type), allocatable, dimension(:) :: gauge_points

    CALL timer_get(run_start_time)

    candidate_score_threshold = 10
    initial_radiusM = 500
    max_radiusM = 4000

    in_dem_file = ''
    in_river_file = ''
    in_point_file = ''
    ref_catch_dir = ''

    tmp_char = ''

    input_is_valid = .true.

    i = 0
    print *, '--- catch_find ---'
    do
        CALL get_command_argument(i, arg)
        if(len_trim(arg) == 0) exit
        if (are_equal(arg, '-dem')) then
            CALL get_command_argument(i+1, in_dem_file)
        elseif (are_equal(arg, '-river')) then
            CALL get_command_argument(i+1, in_river_file)
        elseif (are_equal(arg, '-stations')) then
            if(len_trim(in_point_file) > 0) then
                print *, '-stations cannot be used with -points'
                input_is_valid = .false.
            endif
            CALL get_command_argument(i+1, in_point_file)
        elseif (are_equal(arg, '-ref_catch')) then
            CALL get_command_argument(i+1, ref_catch_dir)
        endif
        i = i + 1
    enddo

    if(check_file_arg(in_dem_file,'-dem').eqv..false.) then
        input_is_valid = .false.
    endif

    if(check_file_arg(in_river_file,'-river').eqv..false.) then
        input_is_valid = .false.
    endif
    if(check_file_arg(in_point_file,'-stations').eqv..false.) then
        input_is_valid = .false.
    endif

    if(len_trim(ref_catch_dir) > 0) then
        print *, 'reference catchments used: ', trim(ref_catch_dir)
    endif

    if(input_is_valid .eqv. .false.) then
        print *, 'command options '
        print *, '-dem <file.asc>   select dem ascii grid file'
        print *, ''
        print *, '-stations <file.txt> select list of station points - (search start points)'
        print *, '-ref_catch <dir>    [optional] use reference catchment masks'
        print *, '           <dir> containing asc files names catchment_id.asc'
        print *, '-river <file.asc>   select river ascii grid file'
        print *, '       searches marked river cells, matches the best by area or reference'
        print *, ''
        print *, ''
        print *, 'Input data description'
        print *, 'dem: sink filled dem (ascii grid)'
        print *, 'river: river mask, optionally labelled with a unique ids '
        print *, 'stations: tab delimited (first line header) containing: '
        print *, '         station_id x_easting y_northing area'
        print *, '         stations outside boundary are skiped'
        print *, ' e.g.:'
        print *, ' catch_find.e -dem dem.asc -river river.asc -stations gauge_outlet.txt'
        stop
    endif

    if(len_trim(ref_catch_dir) > 0) then

        ! if the user didn't add the trailing / add it now
        if(ref_catch_dir(len_trim(ref_catch_dir):len_trim(ref_catch_dir)) /= '/') then
            ref_catch_dir = trim(ref_catch_dir) // '/'
        endif
        if(ref_catch_dir(1:1) == '~') then
            print *, 'sorry, output dir starting with ~ not supported'
            stop
        endif
    endif


    ! input file is in format
    ! tab separated, 4 columns
    ! X and Y are eastings and northings
    ! STATION_NUMBER    X   Y    CATCHMENT_AREA
    point_data_col_id = 1
    point_data_col_x = 2
    point_data_col_y = 3
    point_data_col_ref_area = 4

    print *, 'read station list: ', trim(in_point_file)
    call read_numeric_list(in_point_file, 4, 1, point_data)
    print *, 'stations: ', size(point_data,1)

    print *, 'read dem grid:', trim(in_dem_file)
    CALL timer_get(start_time)
    call read_ascii_grid(in_dem_file, dem_grid, &
        ncols, nrows, xllcorner, yllcorner, cellsize, double_nodata)
    CALL timer_get(end_time)
    call timer_print('read dem grid', start_time, end_time)

    allocate (flow_dir_grid(nrows,ncols))
    allocate (slope_grid(nrows,ncols))

    print *, 'calc_flow_direction'
    CALL timer_get(start_time)
    call calc_flow_direction(nrows, ncols, dem_grid, cellsize, flow_dir_grid, slope_grid)
    CALL timer_get(end_time)
    call timer_print('calc_flow_direction', start_time, end_time)

    ! no longer need dem
    deallocate(dem_grid)

    tmp_char = in_dem_file(1:len_trim(in_dem_file)-4)//'_sfd_slope.asc'

    print *, 'write: ', trim(tmp_char)
    call write_ascii_grid(tmp_char, slope_grid, &
        ncols, nrows, &
        xllcorner, yllcorner, cellsize, -9999.0d0, 5)

    deallocate(slope_grid)

    tmp_char = in_dem_file(1:len_trim(in_dem_file)-4)//'_sfd.asc'

    allocate(flow_dir_grid_int(nrows,ncols))

    flow_dir_grid_int = flow_dir_grid
    ! 127 is max in a fortran byte
    ! change to 128 to match arcgis direction value
    where(flow_dir_grid == 127) flow_dir_grid_int = 128

    print *, 'write: ', trim(tmp_char)
    call write_ascii_grid_int(tmp_char, flow_dir_grid_int, &
        ncols, nrows, &
        xllcorner, yllcorner, cellsize, 0)

    tmp_char = in_dem_file(1:len_trim(in_dem_file)-4)//'_sfd_dir_deg.asc'

    !   conversion to degrees - for arrow visualisation in arcgis
    !   flow_dir_grid_int(:,:) = -9999
    !   where(flow_dir_grid == 1) flow_dir_grid_int = 90
    !   where(flow_dir_grid == 2) flow_dir_grid_int = 135
    !   where(flow_dir_grid == 4) flow_dir_grid_int = 180
    !   where(flow_dir_grid == 8) flow_dir_grid_int = 225
    !   where(flow_dir_grid == 16) flow_dir_grid_int = 270
    !   where(flow_dir_grid == 32) flow_dir_grid_int = 315
    !   where(flow_dir_grid == 64) flow_dir_grid_int = 0
    !   where(flow_dir_grid == 127) flow_dir_grid_int = 45
    !
    !    print *, 'write:', trim(tmp_char)
    !    call write_ascii_grid_int(tmp_char, flow_dir_grid_int, &
    !        ncols, nrows, &
    !        xllcorner, yllcorner, cellsize, 0)

    deallocate(flow_dir_grid_int)

    ! array to write the catchment mask (flow lengths)
    allocate (mask_grid(nrows,ncols))
    ! clear the entire mask
    mask_grid(:,:) = .false.

    print *, 'read river grid: ', trim(in_river_file)
    CALL timer_get(start_time)
    call read_ascii_grid(in_river_file, riv_grid, &
        riv_ncols, riv_nrows, riv_xllcorner, riv_yllcorner, riv_cellsize, double_nodata)
    CALL timer_get(end_time)
    call timer_print('read river grid', start_time, end_time)

    allocate(riv_mask_grid(nrows,ncols))
    riv_mask_grid(:,:) = .false.

    where(riv_grid > 0.001) riv_mask_grid = .true.
    deallocate(riv_grid)

    result_file = in_dem_file(1:len_trim(in_dem_file)-4)//'_station_match.txt'
    print *, 'results file: ', trim(result_file)

    candidate_file= in_dem_file(1:len_trim(in_dem_file)-4)//'_station_candidate.txt'
    print *, 'candidate file: ', trim(result_file)

    ! result file
    ! this file contains all the catchment outlet points on the river cells
    if(file_exists(result_file)) then
        ! read existing file to see which points have already finished
        call read_numeric_list(result_file, 8, 1, point_list_resume)
        print*,'open existing', size(point_list_resume,1)
        open(100, file = result_file, status="old", position="append", action="write", iostat=ioerr)
        if(ioerr/=0) then
            print*,'error opening output file: ', trim(result_file)
            print*,'ensure the directory exists and correct write permissions are set'
            stop
        endif
    else
        ! file does not exist
        open(100, file = result_file, status="new", action="write", iostat=ioerr)

        if(ioerr/=0) then
            print*,'error opening output file: ', trim(result_file)
            print*,'ensure the directory exists and correct write permissions are set'
            stop
        endif

           ! write header to file
        write (100, 97) 'catchment', tab,&
            'x_easting', tab, &
            'y_northing', tab,&
            'Type', tab,&
            'ref_area_km2', tab, &
            'calc_area_m2', tab, &
            'score', tab, &
            'dist', tab, &
            'out_of_bound',tab, &
            'reason'
    end if

    ! candidate_file file
    if(file_exists(candidate_file)) then
        open(101, file = candidate_file, status="old", position="append", action="write", iostat=ioerr)
        if(ioerr/=0) then
            print*,'error opening output file: ', trim(candidate_file)
            print*,'ensure the directory exists and correct write permissions are set'
            stop
        endif
    else
        ! file does not exist
        open(101, file = candidate_file, status="new", action="write", iostat=ioerr)

        if(ioerr/=0) then
            print*,'error opening output file: ', trim(candidate_file)
            print*,'ensure the directory exists and correct write permissions are set'
            stop
        endif

           ! write header to file
        write (101, 97) 'catchment', tab,&
            'x_easting', tab, &
            'y_northing', tab,&
            'Type', tab,&
            'ref_area_km2', tab, &
            'calc_area_m2', tab, &
            'score', tab, &
            'dist', tab, &
            'out_of_bound',tab, &
            'reason'
    end if
    ! write header to terminal
    !write (*, 97) 'catchment', tab, &
    !    'x_easting', tab, &
    !    'y_northing', tab, &
    !    'Type', tab,&
    !    'ref_area_km2', tab, &
    !    'calc_area_m2', tab, &
    !    'score', tab, &
    !    'dist', tab, &
    !    'out_of_bound', tab, &
    !    'reason'


    ! format labels are a bit cryptic
    ! 97 is 19 strings (9 headers and 8 tabs)
    ! 98 is 1 int, 2 (tab floats), int, tab, 4 (tab floats) tab, int, tab, string
97  format ( 19A )
98  format ( I0,2(A,F0.1),A,I0,4(A,F0.1),A,I0,A,A )
    task_count = 0
    allocate(gauge_points(size(point_data,1)))
    do i=1,size(point_data,1)
        gauge_points(i)%x = -1
        gauge_points(i)%y = -1

        catchment_id = nint(point_data(i, point_data_col_id))
        is_complete = .false.
        if(allocated(point_list_resume)) then
            do j=1,size(point_list_resume,1)
                if(nint(point_list_resume(j,1)) == catchment_id) then
                    is_complete = .true.
                endif
            end do
            if(is_complete) then
                print *, 'already processed', catchment_id
                cycle
            endif
        endif

        call NorthingEastingToRowCol( point_data(i,point_data_col_y), &
            point_data(i,point_data_col_x), &
            nrows, xllcorner, yllcorner, cellsize, row, col);

        if(row > 1 .and. row < nrows &
            .and. &
            col > 1 .and. col < ncols) then
            gauge_points(i)%x = col
            gauge_points(i)%y = row
            task_count = task_count + 1
        endif
    end do

    print*,'stations to process:', task_count

    CALL timer_get(start_time)
    last_print_time = start_time
    task_progress = 0
    do i=1,size(point_data,1)
        catchment_id = nint(point_data(i, point_data_col_id))
        is_complete = .false.

        ! check if point disabled
        if( gauge_points(i)%x <0) then
            cycle
        endif
        task_progress = task_progress + 1
        starty = gauge_points(i)%y
        startx = gauge_points(i)%x

        ref_area_km2 = point_data(i, point_data_col_ref_area)

        print *, catchment_id

        !% 1 = 1, 2 = x, 3 = y, 4 = processed
        candidates(:,:) = 0
        candidates_area(:) = 0
        candidates_dist(:) = 0
        candidates_out_of_bounds(:) = -1
        candidate_count = 0

        ! is_complete when error is low enough
        is_complete = .false.
        stop_reason = ''

        search_radius_cells = int(ceiling(initial_radiusM/cellsize))

        ! if reference catchment checking enabled, load the reference asc
        if(len_trim(ref_catch_dir) > 0) then
            write(tmp_char,'(A,I0,A)') &
                trim(ref_catch_dir), &
                catchment_id, '.asc'

            ! check if file exists -and load
            open(unit=1234, iostat=ioerr, file=tmp_char, status='old')
            if (ioerr == 0) then
                close(unit=1234)
                call read_ascii_grid_int(tmp_char, reference_mask_grid, &
                    ref_ncols, ref_nrows, ref_xllcorner, ref_yllcorner, &
                    ref_cellsize, ref_nodata)

                allocate(reference_mask_logical_grid(size(reference_mask_grid,1),size(reference_mask_grid,2)))

                reference_mask_logical_grid = reference_mask_grid > 0

                deallocate(reference_mask_grid)
            else
                print *, 'no mask found match by area:', tmp_char
            endif
        endif

        x = 0
        y = 0
        outlet_x_east = 0
        outlet_y_north = 0
        search_radius_cells_done = 0
        ! In search mode, calculate catchments and record the score
        ! do not write results.
        ! When best score is found, re-calculate and write results
        do while(is_complete .eqv. .false.)

            call find_candidate_river_cells(nrows, ncols, riv_mask_grid, &
                candidates, candidate_count, starty, startx, &
                search_radius_cells, &
                search_radius_cells_done)

            do j=1,candidate_count
                ! skip if already processed
                if(candidates(j,4) == 1) then
                    cycle
                endif
                candidates(j,4) = 1 ! mark as processed
                x = candidates(j,2)
                y = candidates(j,3)

                call calc_catch_cut_flow_dir_mask( nrows, ncols, flow_dir_grid, &
                    y, x, &
                    mask_grid, miny, maxy, minx, maxx, area_count)

                calc_area_m2 = area_count * (cellsize*cellsize)   ! area m^2
                calc_area_km2 = calc_area_m2 / (1000*1000)    !% area km^2

                candidates_area(j) = calc_area_m2
                ! set flag to indicate catchment is out of bounds
                if  (miny == 1 .or. maxy == nrows &
                    .or. minx == 1 .or. maxx == ncols) then
                    candidates_out_of_bounds(j) = 1
                else
                    candidates_out_of_bounds(j) = 0
                endif

                ! if reference catchment checking enabled, and found
                ! score based on mask overlaps
                if (allocated(reference_mask_logical_grid)) then

                    call compare_masks_logical(ncols, nrows, &
                        ref_ncols, ref_nrows, &
                        mask_grid, reference_mask_logical_grid, &
                        xllcorner, yllcorner, &
                        ref_xllcorner, ref_yllcorner, &
                        cellsize, &
                        score, intersect_count, out_count)

                    candidate_result_score(j) = score

                    !print *, 'x', x, 'y', y, 'area(ref:calc)', ref_area_km2, &
                    !    calc_area_km2, &
                    !    'score', score * 100

                else
                    ! score based on best area match
                    score = abs(ref_area_km2 - calc_area_km2) / ref_area_km2
                    candidate_result_score(j) = score

                    !print *, 'x', x, 'y', y, 'area(ref:calc)', ref_area_km2, &
                    !    calc_area_km2, &
                    !    'area % diff', score * 100

                endif

                !% expand the bounday to include a 10 cell border
                !% probably not necessary here, however will catch any off by 1 errors
                !% and is consistant with catch_cut
                miny = max(1,     miny - 10)
                maxy = min(nrows, maxy + 10)
                minx = max(1,     minx - 10)
                maxx = min(ncols, maxx + 10)

                mask_grid(miny:maxy,minx:maxx) = .false.

                call RowColToNorthingEasting(y, x, &
                    nrows, xllcorner, yllcorner, cellsize, &
                    outlet_y_north, outlet_x_east, .true.)

                best_dist = sqrt(real((starty-y)*(starty-y)+(startx-x)*(startx-x)))
                best_candidate_out_of_bounds = candidates_out_of_bounds(j)

                if (allocated(reference_mask_logical_grid)) then
                    stop_reason = 'reference'
                else
                    stop_reason = 'area'
                endif

                write (101, 98) catchment_id, tab, &
                    outlet_x_east, tab, &
                    outlet_y_north, tab, &
                    2, tab, & !node type
                    ref_area_km2, tab, &
                    calc_area_m2, tab,&
                    score * 100, tab,&
                    best_dist * cellsize, tab,&
                    best_candidate_out_of_bounds, tab,&
                    trim(stop_reason)

            enddo

            ! find the processed catchment with the best score
            ! (either area or reference overlap)
            candidate_best = 0
            !candidate_min_score = candidate_result_score(1)
            do j=1,candidate_count
                score = candidate_result_score(j)
                if (candidate_best == 0 .or. score < candidate_min_score) then
                    candidate_min_score = score
                    candidate_best = j
                endif
            enddo

            ! if percentage error below threshhold
            if(candidate_min_score * 100 <= candidate_score_threshold) then
                is_complete = .true.
                if (allocated(reference_mask_logical_grid)) then
                    stop_reason = 'reference: match'
                else
                    stop_reason = 'area: match'
                endif
            else
                if(candidate_count < max_candidate) then
                    if(search_radius_cells * cellsize < max_radiusM) then
                        !print *, 'Expand search to ', nint(search_radius_cells*cellsize), 'm'
                        search_radius_cells_done = search_radius_cells
                        search_radius_cells = search_radius_cells + 2
                    else
                        ! abort search nothing within max_radiusM
                        is_complete = .true.
                        if (allocated(reference_mask_logical_grid)) then
                            stop_reason = 'reference: max radius'
                        else
                            stop_reason = 'area: max radius'
                        endif
                        print *, 'radius excceded, radius    :', search_radius_cells * cellsize,'m score:', candidate_min_score*100
                    endif
                else
                    is_complete = .true.
                    if (allocated(reference_mask_logical_grid)) then
                        stop_reason = 'reference: max candidates'
                    else
                        stop_reason = 'area: max candidates'
                    endif
                    print *, 'candidates excceded, radius:', search_radius_cells * cellsize,'m score:', candidate_min_score*100
                endif
            endif
        enddo

        ! free up the memory used by the reference mask
        if (allocated(reference_mask_logical_grid)) then
            deallocate(reference_mask_logical_grid)
        endif

        if (candidate_best > 0) then
            write_catchment_mask = .true.
            x = candidates(candidate_best,2)
            y = candidates(candidate_best,3)
        else
            print*,'no river cells within radius', max_radiusM, 'm'
            write_catchment_mask = .false.
            x = 0
            y = 0
        endif


        calc_area_m2 = 0
        calc_area_km2 = 0
        best_dist = -1
        best_candidate_out_of_bounds = -1
        candidate_min_score = -1

        if((write_catchment_mask.eqv..true.) .and. x > 0 .and. y > 0) then

            call RowColToNorthingEasting(y, x, &
                nrows, xllcorner, yllcorner, cellsize, &
                outlet_y_north, outlet_x_east, .true.)

            best_dist = sqrt(real((starty-y)*(starty-y)+(startx-x)*(startx-x))) * cellsize

            candidate_min_score = candidate_result_score(candidate_best)
            calc_area_m2 = candidates_area(candidate_best)
            best_candidate_out_of_bounds = candidates_out_of_bounds(candidate_best)
            calc_area_km2 = calc_area_m2 / (1000*1000)       ! area km^2
        endif

        CALL timer_get(end_time)
        call timer_estimate(task_progress, task_count, start_time, end_time, last_print_time)

        !write (*, 98) catchment_id, tab, &
        !    outlet_x_east, tab, &
        !    outlet_y_north, tab, &
        !    2, tab, & !node type
        !    ref_area_km2, tab, &
        !    calc_area_m2, tab,&
        !    candidate_min_score * 100, tab,&
        !    best_dist * cellsize, tab,&
        !    best_candidate_out_of_bounds, tab,&
        !    trim(stop_reason)

        write (100, 98) catchment_id, tab, &
            outlet_x_east, tab, &
            outlet_y_north, tab, &
            2, tab, & !node type
            ref_area_km2, tab, &
            calc_area_m2, tab,&
            candidate_min_score * 100, tab,&
            best_dist, tab,&
            best_candidate_out_of_bounds, tab,&
            trim(stop_reason)

        flush (100)
    enddo
    close (100)

    CALL timer_get(end_time)
    call timer_print('catch_cut', run_start_time, end_time)

    stop


end program catch_cut





