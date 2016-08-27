open History
open Wire
open Maybe

exception Counter_causality of int64

type counter = Cstruct.uint64 [@printer fun fmt -> fprintf fmt "0x%Lx"]
[@@deriving show]

type regime = ZERO | WARMUP | READY
[@@deriving show]

type physical_parameters = {
    skm_scale:          float;
    ts_limit:           float;
    skm_rate:           float;
    e_offset:           float;
    e_offset_qual:      float;

    shift_thres:        counter;    (* rtt shift detection *)

    point_error_thresh:     float;
    rate_error_threshold:   float;
    rate_sanity:            float;

    local_rate_error_threshold: float;
    local_rate_sanity:          float;

    offset_sanity_zero:         float;
    offset_sanity_aging:        float;

    initial_p:         (float * float);
}
[@@deriving show]

type query_ctx = {
    when_sent:  counter;    (* the TSC value when we send it *)
    nonce:      ts;         (* the random number that was in the transmit_timestamp of the packet we sent *)
}

type timestamps = {
    ta:     counter;
    tb:     float               [@printer fun fmt -> fprintf fmt "%.09f"];
    te:     float               [@printer fun fmt -> fprintf fmt "%.09f"];
    tf:     counter;
}
[@@deriving show]

type quality = NG | OK
[@@deriving show]


type sample = {
    quality:        quality;
    timestamps:     timestamps;
    private_data:   private_data;
}
[@@deriving show]

type estimators = {
    pstamp:                          point  option; (* this is a point within samples, not rtt_hat *)
    p_hat_and_error:        (float * float) option;
    p_local:                (float * float) option;
    c:                               float  option;
    theta_hat_and_error:    (float * float * (sample * counter)) option;
}
[@@deriving show]


type output = {
    skm_scale:                      float;
    freshness:                      counter;
    p_hat_and_error:        (float * float);
    p_local:                (float * float) option;
    ca_and_error:           (float * float);
}
[@@deriving show]





let default_parameters =
    let skm_scale           = 1024.0 in
    let ts_limit            = 1.5e-5 in
    let skm_rate            = 2e-7 in
    let rate_error_bound    = 5.0e-7 in

    let initial_p       = (1e-9, 0.0) in            (* FIXME: set this to the right period based on nominal counter frequency *)

    let e_offset        = 1000.0 *. 6.0 *. ts_limit in (* 6 = offset_ratio *)
    let e_offset_qual   = 1000.0 *. 3.0 *. e_offset in
    let shift_thres     = 1L in                     (* FIXME *)

    let point_error_thresh = 100.0 *. 3.0 *. ts_limit in
    let rate_error_threshold    = 100.0 *. rate_error_bound /. 5.0 in
    let rate_sanity             = 100.0 *. rate_error_bound *. 3.0 in

    let local_rate_sanity           = 1000.0 *. rate_error_bound *. 3.0   in
    let local_rate_error_threshold  = 100.0 *. 8.0e-7                    in


    let offset_sanity_zero      = 100.0 *.  ts_limit            in
    let offset_sanity_aging     = 20.0 *.   rate_error_bound    in

    {skm_scale; ts_limit; skm_rate; e_offset; e_offset_qual; initial_p; shift_thres; point_error_thresh; rate_error_threshold; rate_sanity; local_rate_sanity; local_rate_error_threshold; offset_sanity_zero; offset_sanity_aging}

type windows    = {
    top_win_size:       int;
    toplevel:           (point * point);

    halftop_win:        (point * point);

    warmup_win:         (point * point);

    pstamp_win:         (point * point);

    shift_win:          (point * point);
    offset:             (point * point);

    plocal_far:         (point * point);
    plocal_near:        (point * point);
}
[@@deriving show]

let range_of_window w ts =
    range_of ts (fst w) (snd w)

let default_windows params poll_period =
    let history_scale = 3600 * 24 * 7 in        (* seconds *)
    let top_win_size    =               history_scale                           / poll_period  in

    let shift_win       = max 100  ((int_of_float @@ 1e8 *. params.ts_limit )   / poll_period) in
    let offset_size     =           (int_of_float           params.skm_scale)   / poll_period  in

    let toplevel            = (Newest, Older(Newest, top_win_size   - 1)) in
    let halftop_win         = (Newest, Older(Newest, top_win_size/2 - 1)) in
    let shift_win           = (Newest, Older(Newest, shift_win      - 1)) in
    let offset              = (Newest, Older(Newest, offset_size    - 1)) in

    (* plocal stuff:
        * wwidth is the width of each of the plocal_far / plocal_near windows
        * plocal_span is *how far apart* those windows are from each other
    *)

    let plocal_span = 5 * offset_size   in
    let wwidth      = plocal_span / 5   in
    let plocal_near         = (Newest, Older(Newest, wwidth         - 1)) in

    (* this follows from lines 1240 and 1241 in sync_bidir.c.
     *
     * yes, the way plocal_far_centre is defined ("+ wwidth") is kinda icky but
     * it lets us generate the same windows as RADclock when our plocal_span
     * equal to their plocal_win.
     *
     * Also how the far plocal window gets defined in sync_bidir.c:168 in
     * init_plocal (which is called once) seems contradictory with how the far
     * plocal window is defined afterwards, in process_plocal_full. This also
     * seems to violate the preconditions for calling radclock's
     * history_min_slide function in process_plocal_full.
     *
     * I chose to use the far plocal window definitions from
     * process_plocal_full because that is those definitions (and not the
     * init_plocal ones ) actually dictate which ranges RADclock (as of
     * version 73c1151afc24e42b131c47c1ee053e68ce8c075b) looks for plocal
     * points (see radclock_patches/window_bugs.patch for the code used to
     * verify that):
         * Note that radclock's history_min_slide(history *hist, index_t index_curr, index_t j, index_t i)
         * finds a minimum on [j+1,i+1], INCLUSIVE

     * TL;DR the C radclock implementation does weird things with indices but
     * the code here searches over the same intervals / same points as radclock
     * does. Furthermore, the radclock algorithms are not very sensitive to
     * changes in windowing / interval parameters as demonstrated in
     * doi:10.1145/1028788.1028817.
     *)

    let plocal_far_centre   =   Older(Newest, plocal_span + wwidth      ) in
    let plocal_far          =  (Newer(plocal_far_centre,    wwidth/2    ),
                                Older(plocal_far_centre,    wwidth/2 - 1)) in

    let phantom = History (top_win_size, 0, []) in
    let warmup_win = union_range phantom Newest (snd (union_range phantom Newest (snd shift_win) Newest (snd offset)))
                                         Newest (snd plocal_far                                                            ) in

    let warmup_len = match (range_length phantom (fst warmup_win) (snd warmup_win)) with
    | Some x -> x
    | None   -> failwith "invalid warmup interval"
    in
    let pstamp_win = (Newer(Oldest, warmup_len - 1), Oldest) in
    {top_win_size; toplevel; halftop_win; shift_win; offset; plocal_far; plocal_near; pstamp_win; warmup_win}

type sync_state = {
    regime:                 regime;
    parameters:             physical_parameters;
    windows:                windows;
    samples_and_rtt_hat:   (sample * counter) history;  (* sample history and RTT_hat history are zipped together *)
    estimators:             estimators;
}
[@@deriving show]

