*==============================================================================*
*
* PURPOSE   Measure the January-2020 coding artifact instead of asserting it.
*
*           The per-vintage exposure file bins workers on two different code
*           universes (483 codes before 2020, 525 from 2020 on), so employment
*           can cross a bin boundary at 2019m12 -> 2020m1 with nobody changing
*           job. This script quantifies that, per measure, under both keyings:
*
*             VINTAGE     ai_exposure_cps.dta      occ_vintage x occ
*             HARMONIZED  ai_exposure_occ2010.dta  occ2010, one classification
*
* WHY IT EXISTS
*           README.md and PROJECT.md used to quote a set of churn and drift
*           figures that no code in this repository produced. Two independent
*           attempts to reproduce them disagreed with each other and with the
*           published values, and one figure had the wrong sign. Numbers that
*           appear in documentation have to come from somewhere runnable, and
*           this is that somewhere.
*
* OUTPUT    output/tables/boundary_diagnostic.csv  (+ the log)
*             one row per keying x measure:
*               churn_bnd     share of person-month links changing bin at the
*                             2019m12 -> 2020m1 step
*               churn_ctl     the same statistic averaged over every OTHER
*                             December -> January step (the control)
*               churn_stay    churn_bnd among workers who report the SAME
*                             employer as last month (empsame == 2) -- a job
*                             stayer should not change bin at all
*               churn_stay_c  the same statistic over control Dec -> Jan steps,
*                             without which churn_stay cannot be read
*               ctl_min       lowest per-year control Dec -> Jan churn
*               ctl_max       highest per-year control Dec -> Jan churn
*                             (the boundary figure means nothing without the
*                              spread of the controls it is being compared to)
*               drift_bnd     change in top-bin employment share across the
*                             boundary step
*               drift_ctl     mean of that change over control Dec -> Jan steps
*               step_bnd      |monthly change| in top-bin employment share at
*                             the boundary, cross-sectionally
*               step_max_oth  the largest such monthly change anywhere else
*
* NOTE      Person links use cpsidp and IPUMS's month-to-month longitudinal
*           weight (lnkfw1mwt), which is the correct weight for adjacent-month
*           pairs; cross-sectional shares use wtfinl. Sample is the civilian
*           employed (empstat 10, 12) over the window in 0_config.do, matching
*           step C of the build.
*
*           EMPSAME IS RETROSPECTIVE. It reports whether the respondent worked
*           for the same employer as at the PREVIOUS month's interview, so the
*           value that describes a t -> t+1 transition is the one recorded at
*           t+1, not at t. An earlier version of this script read it at t and
*           therefore tested the wrong interval, and because EMPSAME is NIU for
*           month-in-sample 1 and 5 it also forced two of the six rotation
*           groups to "not a stayer". Both are fixed below; the log reports how
*           much of the linked sample the restriction actually covers.
*
*==============================================================================*

capture log close
set more off
set linesize 120
set type double
local dt = "`c(current_date)' `c(current_time)'"
local dt = subinstr("`dt'", ":", "", .)
local dt = subinstr("`dt'", " ", "", .)
log using "02_boundary_diagnostic_`dt'.log", replace
di c(current_date) " " c(current_time)

include 0_config.do

local scorevars aioe estz_total estz_core estz_supp gpt4_beta human_beta ai_applic

*==============================================================================*
* 1. person-month panel: civilian employed, with both sets of bins attached
*==============================================================================*
di as txt _n "== 1  build the person-month panel ======================================="

use cpsidp year month occ occ2010 empstat empsame wtfinl lnkfw1mwt ///
    using "$raw_cps/$cpsfile" ///
    if year >= $cps_yr_min & year <= $cps_yr_max, clear
keep if inlist(empstat, 10, 12)
drop if missing(cpsidp) | cpsidp == 0
gen int t = ym(year, month)
gen int occ_vintage = cond(year >= 2020, 2018, 2010)
di as result "   `=_N' employed person-months, `=r(N)' "

* ---- bins under the per-vintage keying --------------------------------------
* the two files bin on different partitions and now say so in their names
local keepv
local keeph
foreach s of local scorevars {
    local keepv `keepv' `s'_q_vintage
    local keeph `keeph' `s'_q_occ2010
}
merge m:1 occ_vintage occ using "$prcd_data/ai_exposure_cps.dta", ///
    keepusing(`keepv') keep(master match) nogenerate
foreach s of local scorevars {
    rename `s'_q_vintage v_`s'
}

* ---- bins under the harmonized keying ---------------------------------------
merge m:1 occ2010 using "$prcd_data/ai_exposure_occ2010.dta", ///
    keepusing(`keeph') keep(master match) nogenerate
foreach s of local scorevars {
    rename `s'_q_occ2010 h_`s'
}

compress
tempfile panel
save "`panel'"

*==============================================================================*
* 2. cross-sectional monthly step in TOP-BIN employment share
*==============================================================================*
di as txt _n "== 2  monthly top-bin share steps ======================================="

tempfile steps
foreach k in v h {
    foreach s of local scorevars {
        use "`panel'", clear
        keep if !missing(`k'_`s')
        gen byte _top = (`k'_`s' == 5)
        collapse (mean) topshare = _top [aw = wtfinl], by(t)
        sort t
        gen double _d = 100 * (topshare - topshare[_n-1])
        gen str12 keying  = cond("`k'" == "v", "vintage", "harmonized")
        gen str12 measure = "`s'"
        keep keying measure t _d
        capture confirm file "`steps'"
        if !_rc append using "`steps'"
        save "`steps'", replace
    }
}

*==============================================================================*
* 3. adjacent-month person links
*==============================================================================*
di as txt _n "== 3  adjacent-month person links ======================================="

use "`panel'", clear
keep cpsidp t empsame v_* h_*
rename t tnext
rename empsame empsame_next          // EMPSAME at t+1 describes the t -> t+1 step
foreach v of varlist v_* h_* {
    rename `v' n`v'
}
tempfile nxt
save "`nxt'"

use "`panel'", clear
gen int tnext = t + 1
merge 1:1 cpsidp tnext using "`nxt'", keep(match) nogenerate
di as result "   `=_N' adjacent-month person links"

drop if missing(lnkfw1mwt) | lnkfw1mwt <= 0
di as result "   `=_N' with a positive month-to-month link weight"

gen byte boundary = (t == ym(2019, 12))
gen byte decjan   = (month == 12)

* stayer status for the t -> t+1 step comes from EMPSAME as recorded at t+1
gen byte stayer = (empsame_next == 2)

* how much of the linked sample can the restriction actually speak for?
foreach grp in boundary "decjan & !boundary" {
    quietly count if `grp'
    local nl = r(N)
    quietly count if `grp' & missing(empsame_next)
    local nmiss = r(N)
    quietly count if `grp' & empsame_next == 99
    local nniu = r(N)
    quietly count if `grp' & stayer
    di as result "   `grp': `nl' links, `=`nmiss' + `nniu'' with no EMPSAME answer, `r(N)' stayers"
}

*==============================================================================*
* 4. assemble the table
*==============================================================================*
di as txt _n "== 4  results ==========================================================="

tempname pf
tempfile res
postfile `pf' str12 keying str12 measure double(churn_bnd churn_ctl ctl_min ctl_max ///
    churn_stay churn_stay_c drift_bnd drift_ctl step_bnd step_max_oth) using "`res'", replace

foreach k in v h {
    local kn = cond("`k'" == "v", "vintage", "harmonized")
    foreach s of local scorevars {
        quietly {
            * ---- churn among links where both months carry a bin -------------
            gen byte _chg = (`k'_`s' != n`k'_`s') if !missing(`k'_`s') & !missing(n`k'_`s')

            summ _chg if boundary [aw = lnkfw1mwt], meanonly
            local cb = 100 * r(mean)

            summ _chg if decjan & !boundary [aw = lnkfw1mwt], meanonly
            local cc = 100 * r(mean)

            * the pooled control mean hides its own spread: report the range of
            * the individual control Dec -> Jan steps, which is the yardstick the
            * boundary figure has to clear
            local cmin = .
            local cmax = .
            levelsof t if decjan & !boundary, local(_ctlt)
            foreach tt of local _ctlt {
                summ _chg if t == `tt' [aw = lnkfw1mwt], meanonly
                if r(N) > 0 {
                    local one = 100 * r(mean)
                    if `cmin' == . | `one' < `cmin' local cmin = `one'
                    if `cmax' == . | `one' > `cmax' local cmax = `one'
                }
            }

            summ _chg if boundary & stayer [aw = lnkfw1mwt], meanonly
            local cs = 100 * r(mean)

            summ _chg if decjan & !boundary & stayer [aw = lnkfw1mwt], meanonly
            local csc = 100 * r(mean)

            * ---- net drift into the top bin across the step ------------------
            gen byte _t0 = (`k'_`s' == 5)  if !missing(`k'_`s') & !missing(n`k'_`s')
            gen byte _t1 = (n`k'_`s' == 5) if !missing(`k'_`s') & !missing(n`k'_`s')

            summ _t0 if boundary [aw = lnkfw1mwt], meanonly
            local d0 = r(mean)
            summ _t1 if boundary [aw = lnkfw1mwt], meanonly
            local db = 100 * (r(mean) - `d0')

            summ _t0 if decjan & !boundary [aw = lnkfw1mwt], meanonly
            local c0 = r(mean)
            summ _t1 if decjan & !boundary [aw = lnkfw1mwt], meanonly
            local dc = 100 * (r(mean) - `c0')

            drop _chg _t0 _t1
        }

        * ---- cross-sectional monthly step -----------------------------------
        preserve
            use "`steps'", clear
            quietly summ _d if keying == "`kn'" & measure == "`s'" & t == ym(2020, 1)
            local sb = abs(r(mean))
            quietly gen double _abs = abs(_d)
            quietly summ _abs if keying == "`kn'" & measure == "`s'" & t != ym(2020, 1)
            local sm = r(max)
        restore

        post `pf' ("`kn'") ("`s'") (`cb') (`cc') (`cmin') (`cmax') (`cs') (`csc') (`db') (`dc') (`sb') (`sm')
    }
}
postclose `pf'

*==============================================================================*
* 5. report and save
*==============================================================================*
use "`res'", clear
format churn_* ctl_* drift_* step_* %6.2f

di as txt _n "{hline 108}"
di as txt "BOUNDARY DIAGNOSTIC: 2019m12 -> 2020m1 against other December -> January steps"
di as txt "churn = % of person-month links changing bin; drift/step in percentage points"
di as txt "{hline 108}"
list keying measure churn_bnd churn_ctl ctl_min ctl_max churn_stay churn_stay_c, clean noobs
di as txt _n "drift and cross-sectional steps"
list keying measure drift_bnd drift_ctl step_bnd step_max_oth, clean noobs

capture mkdir "$output/tables"
export delimited using "$output/tables/boundary_diagnostic.csv", replace
di as result _n "   wrote $output/tables/boundary_diagnostic.csv"

log close
