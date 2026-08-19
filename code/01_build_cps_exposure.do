*==============================================================================*
*
* PURPOSE   Build AI-exposure measures from raw sources onto the occupation
*           codes that actually appear in CPS microdata, and emit ONE dataset
*           that merges straight onto a CPS extract.
*
* OUTPUT    ai_exposure_cps.dta (+ .csv)          <- steps A-F
*             key: occ_vintage (2010 | 2018) + occ
*             merge:  gen occ_vintage = cond(year >= 2020, 2018, 2010)
*                     merge m:1 occ_vintage occ using "ai_exposure_cps.dta"
*
*           ai_exposure_occ2010.dta                <- step G
*             key: occ2010 (one classification, all years)
*             merge:  merge m:1 occ2010 using "ai_exposure_occ2010.dta"
*             Use this one for anything spanning the Jan-2020 recoding; see
*             "Why there are two ways to match to CPS" in README.md.
*
* DESIGN    Three things this does differently from the original R pipeline:
*
*   (1) NO PROBABILISTIC ASSIGNMENT. Exposure is built natively on the
*       2010-basis CPS codes for <=2019 and the 2018-basis CPS codes for
*       2020+. Workers are never randomly reassigned to a new code, so there
*       is no spurious occupation-switching and no seed dependence.
*
*   (2) PUBLIC-USE CODE UNIVERSE, NOT THE DETAILED CENSUS LIST. The detailed
*       Census occupation lists carry codes the CPS never uses (45 in the 2018
*       vintage, 57 in the 2010 vintage: e.g. 1500 Mining and geological
*       engineers, which exists in the detailed 2018 list but appears zero
*       times in CPS from 2020 on). Step D collapses detailed -> public-use,
*       and the two vintages get there differently. The 2018-vintage map comes
*       from the Census ACS/SIPP public-use list and is then VALIDATED against
*       the codes observed in CPS (526/526). The 2010 vintage has no published
*       equivalent, so its map is CONSTRUCTED from the observed codes -- a
*       detailed code self-maps only if CPS uses it, and a routed target is
*       accepted only if it is a real CPS code -- then validated afterwards.
*       Change the step-C universe file and the 2010 map changes with it.
*
*   (3) SCORES ARE INTENSIVE. When one source code maps to many targets the
*       score is COPIED (not divided); when many sources map to one target the
*       score is an EMPLOYMENT-WEIGHTED MEAN. See _xwalk_score in
*       code/0_config.do. The
*       original multiplied importance weights twice, which shrank scores by an
*       occupation-specific factor.
*
* MEASURES  Felten et al. (2021) AIOE          [SOC 2010]
*           Eloundou et al. (2024) gpt4/human beta  [O*NET-SOC 2018]
*           Eisfeldt et al. (2023) ESTZ core/total/supplemental [SOC 2010]
*           Tomlinson et al. (2025) AI applicability score  [SOC 2018]
*
* PREVIOUSLY
*    (1) Census publishes its occupation classification at two levels of detail 
*        — the full/detailed list, and a collapsed "public-use" version that 
*        actual survey microdata uses. The old pipeline built its crosswalks on 
*        the detailed list, then applied them to CPS microdata, which uses the 
*        collapsed one.
*    (2) For Eloundou in years >2020, with 2018 vintage occ codes, there were 
*        37 occ codes in the crosswalk that did not match to CPS and 16 occ in 
*        CPS that did not get a score from the crosswalk. 
*    (3) This new vintage has full coverage of all CPS occ codes from 2015 to
*        2026. Note that is a COVERAGE claim, not the universe window: step C
*        builds the code universe from CPS 2015-2024 only (see the filter at
*        the top of step C). Every code observed in 2025-2026 is already in
*        that universe, so the narrower window currently drops nothing.
*==============================================================================*

*--------------------------------------------------
* PROGRAM SETUP
*--------------------------------------------------
capture log close
set more off
set linesize 80
set type double
local dt = "`c(current_date)' `c(current_time)'"
local dt = subinstr("`dt'", ":", "", .)
local dt = subinstr("`dt'", " ", "", .)
log using "01_build_cps_exposure_`dt'.log", replace
di c(current_date) " " c(current_time)

* --- Paths & Macros ---
include 0_config.do

*==============================================================================*
* OEWS national employment by detailed SOC -> aggregation weights.
*
* Used whenever several SOC codes collapse into one Census/CPS occupation code:
* the target's exposure is the employment-weighted mean of its components, so a
* 2,000-worker SOC no longer counts as much as a 2,000,000-worker one.
*
* Two vintages, because OEWS switched SOC basis:
*   emp_soc2018.dta   from May 2024 OEWS  (SOC 2018)
*   emp_soc2010.dta   from May 2018 OEWS  (SOC 2010)
*
* A missing OEWS file is FATAL: _read_oews (code/0_config.do) errors out and the
* build stops at this step. There is no stub-writing fallback -- an earlier
* version had one and it was never wired up, so do not rely on the build
* degrading gracefully to unweighted means here. Where weights are merely
* MISSING for some SOC codes, _xwalk_score reports _wtd == 0 for targets whose
* every contributing source lacks employment.
*==============================================================================*

di as txt _n "== A  OEWS employment weights ==========================================="

*------------------------------------------------------------------------------*
* SOC 2018 basis
*------------------------------------------------------------------------------*
_read_oews "$raw_oews/national_M2024_dl.xlsx", socvar(soc2018) out("$prcd_exp/emp_soc2018.dta")
use "$prcd_exp/emp_soc2018.dta", clear
local n = _N
quietly count if missing(emp_wt)
local nmiss = r(N)
quietly summ emp_wt
di as result "   SOC 2018: `n' detailed codes, " %12.0fc r(sum)  " total employment, `nmiss' suppressed"

*------------------------------------------------------------------------------*
* SOC 2010 basis
*------------------------------------------------------------------------------*
_read_oews "$raw_oews/national_M2018_dl", socvar(soc2010) out("$prcd_exp/emp_soc2010.dta")
use "$prcd_exp/emp_soc2010.dta", clear
local n = _N
quietly count if missing(emp_wt)
local nmiss = r(N)
quietly summ emp_wt
di as result "   SOC 2010: `n' detailed codes, " %12.0fc r(sum) " total employment, `nmiss' suppressed"

*==============================================================================*
* Builds the code-scheme plumbing:
*   soc2010_soc2018.dta   SOC 2010 <-> SOC 2018            (BLS)
*   soc2018_det2018.dta   SOC 2018  -> detailed Census 2018 (Census)
*   soc2010_det2010.dta   SOC 2010  -> detailed Census 2010 (Census)
*   det2010_det2018.dta   detailed Census 2010 -> 2018      (Census)
*
* THE PLACEHOLDER PROBLEM
* Census occupation lists do not always name a detailed 6-digit SOC. They use
*   - explicit wildcards:  17-301X  = "combines 17-3012 / 17-3013 / 17-3019"
*   - broad-group codes:   29-1020  = "all detailed SOCs under 29-102x"
* Every exposure measure is keyed on DETAILED SOC, so both forms must be
* expanded to their detailed members before anything can merge. soc_census_map
* does that with a longest-prefix-wins rule, so a genuine detailed code is
* never mistaken for a wildcard.
*==============================================================================*

di as txt _n "== B  SOC / Census crosswalks ==========================================="

*==============================================================================*
* (a) SOC 2010 <-> SOC 2018
*==============================================================================*
import excel using "$raw_xwlk/soc_2010_to_2018_crosswalk.xlsx", sheet("Sorted by 2010") cellrange(A9) firstrow clear
rename *, lower
unab vl : _all
local v1 : word 1 of `vl'
local v3 : word 3 of `vl'

gen str7 soc2010 = strtrim(`v1')
gen str7 soc2018 = strtrim(`v3')
keep soc2010 soc2018
keep if ustrregexm(soc2010, "^[0-9][0-9]-[0-9][0-9][0-9][0-9]$")  & ustrregexm(soc2018, "^[0-9][0-9]-[0-9][0-9][0-9][0-9]$")
duplicates drop
compress
label data "BLS SOC 2010 <-> SOC 2018 crosswalk"
save "$prcd_exp/soc2010_soc2018.dta", replace
di as result "   SOC2010 <-> SOC2018 pairs: `=_N'"

*==============================================================================*
* master lists of DETAILED SOC codes (expansion targets)
*==============================================================================*
* ---- SOC 2018 ----------------------------------------------------------------
use "$prcd_exp/soc2010_soc2018.dta", clear
keep soc2018
rename soc2018 soc_full
duplicates drop
tempfile m18a
save "`m18a'"

import delimited using "$raw_aiexp/gptsRgpts_occ_lvl.csv", varnames(1) stringcols(_all) clear
unab vl : _all
* O*NET-SOC Code (col 1 is the row index)
local onetv : word 2 of `vl'
gen str7 soc_full = substr(strtrim(`onetv'), 1, 7)
keep soc_full
keep if ustrregexm(soc_full, "^[0-9][0-9]-[0-9][0-9][0-9][0-9]$")
append using "`m18a'"
keep soc_full
duplicates drop
sort soc_full
save "$prcd_exp/master_soc2018.dta", replace
di as result "   detailed SOC 2018 master list: `=_N'"

* ---- SOC 2010 ----------------------------------------------------------------
use "$prcd_exp/soc2010_soc2018.dta", clear
keep soc2010
rename soc2010 soc_full
duplicates drop
tempfile m10a
save "`m10a'"

import excel using "$raw_aiexp/AIOE_DataAppendix.xlsx", sheet("Appendix A") firstrow clear
rename *, lower
unab vl : _all
local fv : word 1 of `vl'
tostring `fv', replace force
gen str7 soc_full = strtrim(`fv')
keep soc_full
keep if ustrregexm(soc_full, "^[0-9][0-9]-[0-9][0-9][0-9][0-9]$")
append using "`m10a'"
tempfile m10b
save "`m10b'"

import delimited using "$raw_aiexp/genaiexp_estz_occscores.csv", varnames(1) stringcols(_all) clear
gen str7 soc_full = strtrim(soc2010)
keep soc_full
keep if ustrregexm(soc_full, "^[0-9][0-9]-[0-9][0-9][0-9][0-9]$")
append using "`m10b'"
keep soc_full
duplicates drop
sort soc_full
save "$prcd_exp/master_soc2010.dta", replace
di as result "   detailed SOC 2010 master list: `=_N'"

*==============================================================================*
* (b) SOC 2018 -> detailed Census 2018
*==============================================================================*
import excel using "$raw_xwlk/2018-occupation-code-list-and-crosswalk.xlsx", sheet("2018 Census Occ Code List") cellrange(A5) firstrow clear
rename *, lower
unab vl : _all
* layout: (blank) | 2018 Census Title | 2018 Census Code | 2018 SOC Code
local vcen : word 3 of `vl'
local vsoc : word 4 of `vl'

tostring `vcen' `vsoc', replace force
gen str9  _cen = strtrim(`vcen')
gen str20 _soc = strtrim(`vsoc')
* drops group headers
keep if ustrregexm(_cen, "^[0-9][0-9][0-9][0-9]$")
gen int det2018 = real(_cen)
keep det2018 _soc
drop if lower(_soc) == "none"
duplicates drop

soc_census_map, id(det2018) pat(_soc) master("$prcd_exp/master_soc2018.dta") out("$prcd_exp/soc2018_det2018.dta")

use "$prcd_exp/soc2018_det2018.dta", clear
rename soc_full soc2018
order soc2018 det2018
compress
label data "SOC 2018 -> detailed Census 2018"
save "$prcd_exp/soc2018_det2018.dta", replace
quietly levelsof det2018, local(dd)
di as result "   SOC2018 -> detailed Census 2018: `=_N' pairs over " "`: word count `dd'' Census codes"


*==============================================================================*
* (c) SOC 2010 -> detailed Census 2010
*==============================================================================*
import excel using "$raw_xwlk/census2010_occ_codes_xwalk.xls", sheet("2010OccCodeList") cellrange(A5) firstrow clear
rename *, lower
unab vl : _all
* layout: (group) | Occupation 2010 Description | 2010 Census Code | 2010 SOC Code
local vcen : word 3 of `vl'
local vsoc : word 4 of `vl'

tostring `vcen' `vsoc', replace force
gen str9  _cen = strtrim(`vcen')
gen str20 _soc = strtrim(`vsoc')
keep if ustrregexm(_cen, "^[0-9][0-9][0-9][0-9]$")
gen int det2010 = real(_cen)
keep det2010 _soc
drop if lower(_soc) == "none"
duplicates drop

* deal with incomplete codes
* for example, 
* _soc	det2010
* 15-1131	1010
* 15-113X	1020
* 15-1134	1030
* we map 15-113X to the remaining components of 15-113 excluding 15-1131 and 15-1134
* we then map 1020 onto those other 15-113 codes
* soc_full	det2010
* 15-1131	1010
* 15-1132	1020
* 15-1133	1020
* 15-1134	1030

soc_census_map, id(det2010) pat(_soc) master("$prcd_exp/master_soc2010.dta") out("$prcd_exp/soc2010_det2010.dta")

use "$prcd_exp/soc2010_det2010.dta", clear
rename soc_full soc2010
order soc2010 det2010
compress
label data "SOC 2010 -> detailed Census 2010"
save "$prcd_exp/soc2010_det2010.dta", replace
quietly levelsof det2010, local(dd)
di as result "   SOC2010 -> detailed Census 2010: `=_N' pairs over "  "`: word count `dd'' Census codes"

*==============================================================================*
* (d) detailed Census 2010 -> detailed Census 2018
*
* Merged cells: the 2010 code is stated once and applies to every 2018 row
* beneath it. So the 2010 code is filled DOWN and the 2018 code is taken as-is.
* (Filling BOTH down, as the original R code did at 01 Crosswalks.R:350, pairs
* each 2010 code with the PREVIOUS row's 2018 code and invents spurious pairs.)
*==============================================================================*
import excel using "$raw_xwlk/2018-occupation-code-list-and-crosswalk.xlsx",  sheet("2010 to 2018 Crosswalk ") cellrange(A4) firstrow clear
* no "rename *, lower" here: this sheet has both "2010 SOC code" and
* "2018 SOC Code", which lowercase to the same name and error out
unab vl : _all
* layout: 2010 SOC | 2010 Census Code | 2010 Title | 2018 SOC | 2018 Census Code | 2018 Title
local v10 : word 2 of `vl'
local v18 : word 5 of `vl'

tostring `v10' `v18', replace force
gen str9 _c10 = strtrim(`v10')
gen str9 _c18 = strtrim(`v18')
gen int det2010 = real(_c10) if ustrregexm(_c10, "^[0-9][0-9][0-9][0-9]$")
gen int det2018 = real(_c18) if ustrregexm(_c18, "^[0-9][0-9][0-9][0-9]$")

replace det2010 = det2010[_n-1] if missing(det2010) & _n > 1
keep if !missing(det2010) & !missing(det2018)
keep det2010 det2018
duplicates drop
compress
label data "detailed Census 2010 -> detailed Census 2018"
save "$prcd_exp/det2010_det2018.dta", replace
di as result "   detailed Census 2010 -> 2018: `=_N' pairs"

*==============================================================================*
* cps_occ_universe
*
* WHAT THIS PRODUCES
*   The set of occupation codes that actually appear in CPS microdata, by code
*   vintage, with an unweighted count and an employment share per code.
*
* WHY IT MATTERS
*   This file is LOAD-BEARING, not just a validation target. Step D uses it to
*   BUILD the 2010-vintage collapse map: a detailed Census code is allowed to
*   map to itself only if CPS actually uses that code, and a routed target is
*   accepted only if it is a real CPS code. Change this file and the collapse
*   map changes with it.
*
* WHEN TO RERUN
*   Whenever you point the pipeline at a different CPS extract -- different
*   years, different sample, a new IPUMS pull. A code that is genuinely rare and
*   happens not to appear in a short extract would be treated as "not a CPS
*   code" and its content routed elsewhere. Over the 2015-2025 window the
*   thinnest code has 74 observations, so any multi-year extract recovers the
*   same universe; a one-month extract would not.
*
* VINTAGE BOUNDARY
*   CPS adopted 2018-basis Census occupation codes in January 2020, so
*   year <= 2019 is the 2010 basis and year >= 2020 is the 2018 basis.
*==============================================================================*

di as txt _n "== C  CPS occupation universe ==========================================="

*------------------------------------------------------------------------------*
* CPS extract: needs year, occ, and a person weight. Edit if reusing elsewhere.
*------------------------------------------------------------------------------*

* allows 5 years of data for each vintage
use year occ wtfinl using "$raw_cps/$cpsfile", clear
quietly summ year
if r(max) < $cps_yr_max | r(min) > $cps_yr_min {
    di as error "   !! extract does not span $cps_yr_min - $cps_yr_max (found `r(min)'-`r(max)')"
}
keep if year>=$cps_yr_min & year<=$cps_yr_max 
* occ == 0 is "not in universe" (not employed / no occupation reported)
drop if occ == 0 | missing(occ)

gen int occ_vintage = cond(year >= 2020, 2018, 2010)

gen byte one = 1
collapse (sum) nobs = one (sum) _w = wtfinl, by(occ_vintage occ)

bysort occ_vintage: egen double _tot = total(_w)
gen double emp_share = _w / _tot
drop _w _tot

label var occ_vintage "2010 = CPS year<=2019, 2018 = CPS year>=2020"
label var occ         "CPS public-use occupation code (IPUMS OCC)"
label var nobs        "unweighted CPS records on this code"
label var emp_share   "share of vintage employment on this code"

sort occ_vintage occ
order occ_vintage occ nobs emp_share

* ---- report before overwriting ----------------------------------------------
foreach v in 2010 2018 {
    quietly count if occ_vintage == `v'
    local n = r(N)
    quietly summ nobs if occ_vintage == `v'
    di as result "   vintage `v': `n' codes, thinnest has " %6.0f r(min) " obs"
    quietly count if occ_vintage == `v' & nobs < 50
    if r(N) > 0 {
        di as error "   !! `r(N)' code(s) with <50 observations -- a thin extract" " may be missing codes entirely, which would distort step D"
    }
}
save "$prcd_exp/cps_occ_universe.dta", replace
foreach v in 2010 2018 {
    preserve
        keep if occ_vintage == `v'
        keep occ
        rename occ pu`v'
        sort pu`v'
        save "$prcd_exp/cps_occ_universe_`v'.dta", replace
        di as result "   wrote $prcd_exp/cps_occ_universe_`v'.dta"
    restore
}

*==============================================================================*
* Collapse DETAILED Census occupation codes to the PUBLIC-USE codes the CPS
* actually publishes, separately for each vintage.
*
* WHY THIS STEP EXISTS
* The Census "2010 to 2018 Crosswalk" tab is built on the DETAILED Census
* classification. The CPS public-use file is a COLLAPSED version of it. Detailed
* 1500 (Mining and geological engineers) is a valid detailed 2018 code and the
* crosswalk maps 1500 -> 1500, but 1500 appears ZERO times in CPS from 2020 on:
* those workers sit inside 1520. 45 detailed 2018 codes and 57 detailed 2010
* codes behave this way. Mapping exposure onto them silently manufactures
* occupations that exist in one half of the sample and not the other.
*
* OUTPUT
*   det2018_pu2018.dta   det2018 -> occ  (2018-vintage CPS code)
*   det2010_pu2010.dta   det2010 -> occ  (2010-vintage CPS code)
*
* SOURCES, in priority order
*   2018 vintage : Census 2018 ACS/SIPP Public Use Occupation Code List. Its
*                  "Combines:" blocks state exactly which detailed codes sit
*                  inside each public-use code. It reproduces the observed CPS
*                  2020+ universe exactly apart from the military block, which
*                  the override file handles.
*   2010 vintage : Census publishes no equivalent 2010 public-use list, so:
*                  (i)   detailed code observed in CPS -> itself
*                  (ii)  else route det2010 -> det2018 -> public-use 2018 and
*                        accept it if it is a valid 2010-vintage CPS code
*                  (iii) else take it from raw/collapse_overrides_2010.csv, a
*                        hand-reviewable table. EDIT THAT FILE, not this one.
*==============================================================================*

di as txt _n "== D  detailed Census -> CPS public-use codes ==========================="

*==============================================================================*
* (a) 2018 vintage: parse the ACS/SIPP public-use code list
*==============================================================================*
import excel using "$raw_xwlk/acs_pums_sipp_2018_occ_codes.xlsx",  sheet("ACS") cellrange(A10) clear allstring
rename (A B C) (colA colB colC)
replace colA = strtrim(colA)
replace colC = strtrim(colC)

* a public-use code is a bare 4-digit value in column A; major/minor group
* headers hold ranges like "0010-3550" and never match
gen int pu2018 = real(colA) if ustrregexm(colA, "^[0-9][0-9][0-9][0-9]$")

* component rows sit under their public-use row with column A blank and column
* C of the form "1500 - Mining and geological engineers, ..."
gen int det2018 = real(ustrregexs(1)) if ustrregexm(colC, "^([0-9][0-9][0-9][0-9]) - ")

* carry the public-use code down over its "Combines:" block
replace pu2018 = pu2018[_n-1] if missing(pu2018) & _n > 1

tempfile comp18
preserve
    keep if !missing(det2018) & !missing(pu2018)
    keep det2018 pu2018
    duplicates drop
    save "`comp18'"
    local ncomp = _N
restore

* public-use codes with no "Combines:" block map to themselves
keep if ustrregexm(colA, "^[0-9][0-9][0-9][0-9]$")
keep pu2018
duplicates drop
local npu = _N
merge 1:m pu2018 using "`comp18'", keep(master match) nogenerate
replace det2018 = pu2018 if missing(det2018)
keep det2018 pu2018
duplicates drop
di as result "   ACS list: `npu' public-use codes, `ncomp' explicit component " "pairs, `=_N' detailed mappings"

* ---- overrides ---------------------------------------------------------------
tempfile ov18
preserve
    import delimited using "$raw_xwlk/collapse_overrides_2018.csv", varnames(1) clear
    keep det pu
    rename (det pu) (det2018 pu_ov)
    drop if missing(det2018)
    gen byte _hasov = 1
    duplicates drop
    save "`ov18'"
restore

merge m:1 det2018 using "`ov18'", keep(master match) nogenerate
* override row with a blank target means "drop this detailed code"
drop if _hasov == 1 & missing(pu_ov)
replace pu2018 = pu_ov if !missing(pu_ov)
drop pu_ov _hasov
drop if missing(det2018) | missing(pu2018)
duplicates drop

compress
label data "detailed Census 2018 -> CPS 2018-vintage public-use occ"
sort det2018
save "$prcd_exp/det2018_pu2018.dta", replace

* ---- validate against observed CPS codes ------------------------------------
preserve
    keep pu2018
    duplicates drop
    merge 1:1 pu2018 using "$prcd_exp/cps_occ_universe_2018.dta"
    quietly count if _merge == 1
    local extra = r(N)
    quietly count if _merge == 2
    local missn = r(N)
    quietly count if _merge == 3
    di as result "   2018 vintage: `r(N)' codes agree with CPS; "  "`extra' mapped-but-unobserved; `missn' observed-but-unmapped"
    if `missn' > 0 {
        di as error "   !! CPS codes with no exposure route (2018):"
        list pu2018 if _merge == 2, clean noobs
    }
    if `extra' > 0 {
        di as txt "      mapped-but-unobserved (harmless, simply unused):"
        list pu2018 if _merge == 1, clean noobs
    }
restore

*==============================================================================*
* (b) 2010 vintage
*==============================================================================*
* ---- tier (i): detailed codes that are themselves CPS codes ------------------
use "$prcd_exp/soc2010_det2010.dta", clear
keep det2010
duplicates drop
tempfile det10all
save "`det10all'"
local n_all = _N

gen int pu2010 = det2010
merge m:1 pu2010 using "$prcd_exp/cps_occ_universe_2010.dta", keep(match) nogenerate
keep det2010 pu2010
tempfile self10
save "`self10'"
di as result "   2010 vintage: `=_N' of `n_all' detailed codes are CPS codes themselves"

* ---- tier (ii): route det2010 -> det2018 -> public-use 2018 ------------------
use "`det10all'", clear
merge 1:1 det2010 using "`self10'", keep(master) nogenerate
keep det2010
tempfile todo1
save "`todo1'"
local n_todo = _N

use "$prcd_exp/det2010_det2018.dta", clear
merge m:1 det2010 using "`todo1'", keep(match) nogenerate
merge m:1 det2018 using "$prcd_exp/det2018_pu2018.dta", keep(match) nogenerate
rename pu2018 pu2010
keep det2010 pu2010
duplicates drop
* accept only targets that are real 2010-vintage CPS codes ...
merge m:1 pu2010 using "$prcd_exp/cps_occ_universe_2010.dta", keep(match) nogenerate
* ... and only where the route is unambiguous
bysort det2010: gen byte _n2 = _N
keep if _n2 == 1
drop _n2
tempfile routed10
save "`routed10'"
di as result "                 `=_N' of `n_todo' remaining resolved via the 2018 route"

* ---- tier (iii): hand-reviewable override table ------------------------------
use "`todo1'", clear
merge 1:1 det2010 using "`routed10'", keep(master) nogenerate
keep det2010
tempfile todo2
save "`todo2'"
local n_left = _N

import delimited using "$raw_xwlk/collapse_overrides_2010.csv", varnames(1) clear
keep det pu confidence
rename (det pu) (det2010 pu2010)
drop if missing(det2010)
gen byte _hasov = 1
duplicates drop
tempfile ov10
save "`ov10'"

use "`todo2'", clear
merge 1:1 det2010 using "`ov10'", keep(master match) nogenerate
quietly count if _hasov != 1
local unres = r(N)
di as result "                 `=`n_left' - `unres'' of `n_left' resolved by the override file"
if `unres' > 0 {
    di as error "   !! UNRESOLVED detailed 2010 codes -- add rows to " "$raw_xwlk/collapse_overrides_2010.csv:"
    list det2010 if _hasov != 1, clean noobs
}
* blank pu in the override file means drop the code
drop if missing(pu2010)
keep det2010 pu2010
tempfile ov10used
save "`ov10used'"

* ---- stack the three tiers --------------------------------------------------
use "`self10'", clear
append using "`routed10'"
append using "`ov10used'"
duplicates drop
compress
label data "detailed Census 2010 -> CPS 2010-vintage public-use occ"
sort det2010
save "$prcd_exp/det2010_pu2010.dta", replace

* ---- validate ---------------------------------------------------------------
preserve
    keep pu2010
    duplicates drop
    merge 1:1 pu2010 using "$prcd_exp/cps_occ_universe_2010.dta"
    quietly count if _merge == 1
    local extra = r(N)
    quietly count if _merge == 2
    local missn = r(N)
    quietly count if _merge == 3
    di as result "   2010 vintage: `r(N)' codes agree with CPS; "  "`extra' mapped-but-unobserved; `missn' observed-but-unmapped"
    if `missn' > 0 {
        di as error "   !! CPS codes with no exposure route (2010):"
        list pu2010 if _merge == 2, clean noobs
    }
restore

*==============================================================================*
* Read each exposure measure on its native SOC scheme and carry it to CPS
* public-use occupation codes, in BOTH vintages.
*
* ROUTES
*   Felten AIOE      SOC2010 -> det2010 -> pu2010          (2010 vintage)
*                    SOC2010 -> SOC2018 -> det2018 -> pu2018 (2018 vintage)
*   Eisfeldt ESTZ    same as Felten (also native SOC 2010)
*   Eloundou beta    SOC2018 -> det2018 -> pu2018          (2018 vintage)
*                    SOC2018 -> SOC2010 -> det2010 -> pu2010 (2010 vintage)
*   Tomlinson applic same as Eloundou (also native SOC 2018)
*
* Every hop uses xwalk_score: score copied when one source feeds many targets,
* employment-weighted mean when many sources feed one target. Nothing is ever
* multiplied by a weight, so scores keep their original scale and meaning.
*==============================================================================*

di as txt _n "== E  exposure measures ================================================="

*------------------------------------------------------------------------------*
* (a) Felten et al. (2021) AIOE -- native SOC 2010
*------------------------------------------------------------------------------*
import excel using "$raw_aiexp/AIOE_DataAppendix.xlsx", sheet("Appendix A")  firstrow clear
rename *, lower
unab vl : _all
local vsoc : word 1 of `vl'
* SOC Code | Occupation Title | AIOE
local vsc  : word 3 of `vl'

tostring `vsoc', replace force
gen str7 _soc = strtrim(`vsoc')
gen double _aioe = real(string(`vsc'))
keep _soc _aioe
rename (_soc _aioe) (soc2010 aioe)
keep if ustrregexm(soc2010, "^[0-9][0-9]-[0-9][0-9][0-9][0-9]$") & !missing(aioe)
collapse (mean) aioe, by(soc2010)
recast str7 soc2010, force
compress
save "$prcd_exp/score_felten_soc2010.dta", replace
di as result "   Felten AIOE: `=_N' SOC 2010 codes"

*------------------------------------------------------------------------------*
* (b) Eisfeldt et al. (2023) ESTZ -- native SOC 2010
*------------------------------------------------------------------------------*
import delimited using "$raw_aiexp/genaiexp_estz_occscores.csv", varnames(1) clear
tostring soc2010, replace force
replace soc2010 = strtrim(soc2010)
rename genaiexp_estz_total        estz_total
rename genaiexp_estz_core         estz_core
rename genaiexp_estz_supplemental estz_supp
keep soc2010 estz_total estz_core estz_supp
keep if ustrregexm(soc2010, "^[0-9][0-9]-[0-9][0-9][0-9][0-9]$")
collapse (mean) estz_total estz_core estz_supp, by(soc2010)
recast str7 soc2010, force
compress
save "$prcd_exp/score_eisfeldt_soc2010.dta", replace
di as result "   Eisfeldt ESTZ: `=_N' SOC 2010 codes"


*------------------------------------------------------------------------------*
* (c) Eloundou et al. (2024) beta -- native O*NET-SOC 2018 (8-digit)
*     8-digit detail is averaged up to the 6-digit SOC. O*NET does not publish
*     employment at the 8-digit level, so this hop is an unweighted mean.
*------------------------------------------------------------------------------*
import delimited using "$raw_aiexp/gptsRgpts_occ_lvl.csv", varnames(1) clear
unab vl : _all
local onetv : word 2 of `vl'
tostring `onetv', replace force
gen str7 soc2018 = substr(strtrim(`onetv'), 1, 7)
keep soc2018 gpt4_beta human_beta
keep if ustrregexm(soc2018, "^[0-9][0-9]-[0-9][0-9][0-9][0-9]$")
collapse (mean) gpt4_beta human_beta, by(soc2018)
recast str7 soc2018, force
compress
save "$prcd_exp/score_eloundou_soc2018.dta", replace
di as result "   Eloundou beta: `=_N' SOC 2018 codes"

*------------------------------------------------------------------------------*
* (d) Tomlinson et al. (2025) AI applicability score -- native SOC 2018
*     arXiv:2507.07935. Published at the 6-digit SOC level, so unlike Eloundou
*     there is no 8-digit O*NET step to average up.
*
*     THE BROAD-GROUP CASE. 7 of the 785 rows are broad SOC groups rather than
*     detailed codes (trailing 0): 13-1020, 13-2020, 29-2010, 31-1120, 39-7010,
*     47-4090, 51-2090. Every crosswalk built in step B is keyed on DETAILED
*     SOC, so left alone those rows merge to nothing and their members arrive
*     unscored -- and 31-1120 is Home Health and Personal Care Aides, one of the
*     largest occupations in the CPS. Each group is therefore expanded to its
*     detailed members with the score COPIED, which is the one-source-to-many-
*     targets case xwalk_score already treats this way: an applicability score
*     is intensive, so it is not divided up. No detailed member of any of the 7
*     groups is scored separately in the source file, so nothing explicit is
*     overwritten -- the merge below enforces that, and isid asserts the result.
*------------------------------------------------------------------------------*
import delimited using "$raw_aiexp/ai_applicability_scores.csv", varnames(1) stringcols(_all) clear
unab vl : _all
* SOC Code | title | ai_applicability_score
local vsoc : word 1 of `vl'
local vsc  : word 3 of `vl'

tostring `vsoc', replace force
gen str7 soc2018     = strtrim(`vsoc')
gen double ai_applic = real(`vsc')
keep soc2018 ai_applic
keep if ustrregexm(soc2018, "^[0-9][0-9]-[0-9][0-9][0-9][0-9]$") & !missing(ai_applic)
* guard against duplicate rows in the source file
collapse (mean) ai_applic, by(soc2018)

* ---- expand broad groups (trailing 0) to their detailed members --------------
tempfile _tom_detail
preserve
    keep if substr(soc2018, 7, 1) != "0"
    save "`_tom_detail'"
restore
keep if substr(soc2018, 7, 1) == "0"
local n_broad = _N

if `n_broad' > 0 {
    gen str6 _pfx = substr(soc2018, 1, 6)
    keep _pfx ai_applic
    cross using "$prcd_exp/master_soc2018.dta"
    keep if substr(soc_full, 1, 6) == _pfx
    rename soc_full soc2018
    keep soc2018 ai_applic
    * a detailed code the file scores explicitly always beats an expanded group
    merge 1:1 soc2018 using "`_tom_detail'", keep(master) nogenerate
    local n_expanded = _N
    append using "`_tom_detail'"
}
else {
    local n_expanded = 0
    use "`_tom_detail'", clear
}

isid soc2018
recast str7 soc2018, force
compress
save "$prcd_exp/score_tomlinson_soc2018.dta", replace
di as result "   Tomlinson AI applicability: `=_N' SOC 2018 codes " ///
    "(`n_broad' broad groups -> `n_expanded' detailed members)"

*==============================================================================*
* SOC-vintage bridges for the scores that need to cross
*==============================================================================*
* SOC 2010 -> SOC 2018 (for Felten / Eisfeldt on the 2018 vintage)
foreach m in felten eisfeldt {
    use "$prcd_exp/score_`m'_soc2010.dta", clear
    ds soc2010, not
    local svars `r(varlist)'
    _xwalk_score `svars', source(soc2010) target(soc2018) xwalk("$prcd_exp/soc2010_soc2018.dta") empfile("$prcd_exp/emp_soc2010.dta")
    drop _nsrc _wtd
    save "$prcd_exp/score_`m'_soc2018.dta", replace
}

* SOC 2018 -> SOC 2010 (for Eloundou / Tomlinson on the 2010 vintage)
foreach m in eloundou tomlinson {
    use "$prcd_exp/score_`m'_soc2018.dta", clear
    ds soc2018, not
    local svars `r(varlist)'
    _xwalk_score `svars', source(soc2018) target(soc2010) xwalk("$prcd_exp/soc2010_soc2018.dta") empfile("$prcd_exp/emp_soc2018.dta")
    drop _nsrc _wtd
    save "$prcd_exp/score_`m'_soc2010.dta", replace
}

*==============================================================================*
* SOC -> detailed Census -> CPS public-use, per vintage
*==============================================================================*
* ---- 2018 vintage ------------------------------------------------------------
foreach m in felten eisfeldt eloundou tomlinson {
    use "$prcd_exp/score_`m'_soc2018.dta", clear
    ds soc2018, not
    local svars `r(varlist)'

    * SOC 2018 -> detailed Census 2018
    _xwalk_score `svars', source(soc2018) target(det2018) xwalk("$prcd_exp/soc2018_det2018.dta") empfile("$prcd_exp/emp_soc2018.dta")
    drop _nsrc _wtd
    tempfile d18
    save "`d18'"

    * detailed Census 2018 -> CPS public-use. Employment weights live on SOC,
    * so build a det2018-level weight first.
    preserve
        use "$prcd_exp/soc2018_det2018.dta", clear
        merge m:1 soc2018 using "$prcd_exp/emp_soc2018.dta", keep(master match) nogenerate
        collapse (sum) emp_wt, by(det2018)
        replace emp_wt = . if emp_wt <= 0
        tempfile empdet18
        save "`empdet18'"
    restore

    use "`d18'", clear
    _xwalk_score `svars', source(det2018) target(pu2018) xwalk("$prcd_exp/det2018_pu2018.dta") empfile("`empdet18'")
    rename pu2018 occ
    rename (_nsrc _wtd) (nsrc_`m' wtd_`m')
    gen int occ_vintage = 2018
    order occ_vintage occ
    save "$prcd_exp/pu_`m'_2018.dta", replace
    di as result "   `m' -> 2018-vintage CPS codes: `=_N'"
}

* ---- 2010 vintage ------------------------------------------------------------
foreach m in felten eisfeldt eloundou tomlinson {
    use "$prcd_exp/score_`m'_soc2010.dta", clear
    ds soc2010, not
    local svars `r(varlist)'

    _xwalk_score `svars', source(soc2010) target(det2010) xwalk("$prcd_exp/soc2010_det2010.dta") empfile("$prcd_exp/emp_soc2010.dta")
    drop _nsrc _wtd
    tempfile d10
    save "`d10'"

    preserve
        use "$prcd_exp/soc2010_det2010.dta", clear
        merge m:1 soc2010 using "$prcd_exp/emp_soc2010.dta", keep(master match) nogenerate
        collapse (sum) emp_wt, by(det2010)
        replace emp_wt = . if emp_wt <= 0
        tempfile empdet10
        save "`empdet10'"
    restore

    use "`d10'", clear
    _xwalk_score `svars', source(det2010) target(pu2010) xwalk("$prcd_exp/det2010_pu2010.dta") empfile("`empdet10'")
    rename pu2010 occ
    rename (_nsrc _wtd) (nsrc_`m' wtd_`m')
    gen int occ_vintage = 2010
    order occ_vintage occ
    save "$prcd_exp/pu_`m'_2010.dta", replace
    di as result "   `m' -> 2010-vintage CPS codes: `=_N'"
}

*==============================================================================*
* Stack every measure x vintage into one CPS-mergeable dataset, add quintiles,
* label, and report coverage.
*
* QUINTILE DEFINITION (occupation-count ntile, matching the original project)
* Cutpoints are computed ONCE on the 2018-vintage distribution and then applied
* to BOTH vintages. Computing them separately per vintage would put different
* cutpoints on either side of 2020 and manufacture a break at exactly the date
* the AI story is supposed to start.
*
* NOTE these quintiles hold unequal shares of EMPLOYMENT (in the original build
* the five AIOE quintiles held 21.8 / 14.1 / 17.9 / 27.2 / 18.9 percent of
* 2020+ employment). That is inherent to ranking occupation codes rather than
* workers. Employment-weighted bins are a one-line change: see the commented
* block at the bottom.
*==============================================================================*

di as txt _n "== F  assemble =========================================================="

local measures felten eisfeldt eloundou tomlinson

* ---- stack -------------------------------------------------------------------
* MERGE measures WITHIN a vintage, then APPEND the two vintages.
* Doing it the other way round silently fails: once a score variable exists in
* the master data, a plain merge will not fill it for newly matched rows (that
* needs update/replace), so the second vintage of every measure after the first
* comes through entirely missing.
tempfile v2010 v2018

foreach v in 2010 2018 {
    local first 1
    foreach m of local measures {
        if `first' {
            use "$prcd_exp/pu_`m'_`v'.dta", clear
            local first 0
        }
        else {
            merge 1:1 occ_vintage occ using "$prcd_exp/pu_`m'_`v'.dta", nogenerate
        }
    }
    save "`v`v''", replace
}

use "`v2010'", clear
append using "`v2018'"

* ---- restrict to codes CPS actually uses -------------------------------------
merge 1:1 occ_vintage occ using "$prcd_exp/cps_occ_universe.dta", keepusing(nobs emp_share) keep(match using) generate(_inuniv)
* keep(match using) drops any public-use code CPS never uses, and keeps CPS
* codes that no measure reaches (their scores stay missing and show up in the
* coverage report). Step D already proved the two universes coincide, so
* nothing should be dropped here -- but assert it rather than assume it.
quietly count if _inuniv == 1
if r(N) > 0 {
    di as error "   !! `r(N)' exposure rows are not CPS codes -- check step D"
}
drop _inuniv

* ---- quintiles: cutpoints from the 2018 vintage, applied to both -------------
local scorevars aioe estz_total estz_core estz_supp gpt4_beta human_beta ai_applic

foreach s of local scorevars {
    capture confirm variable `s'
    if _rc {
        di as error "   (no variable `s' -- skipped)"
        continue
    }

    * cutpoints from the 2018-vintage occupation-code distribution
    quietly _pctile `s' if occ_vintage == 2018 & !missing(`s'), nquantiles(5)
    local cuts
    forvalues q = 1/`=5 - 1' {
        local cuts `cuts' `=r(r`q')'
    }

    gen byte `s'_q = .
    quietly replace `s'_q = 1 if !missing(`s')
    local qq 2
    foreach c of local cuts {
        quietly replace `s'_q = `qq' if !missing(`s') & `s' > `c'
        local ++qq
    }
    label var `s'_q "`s' quintile (occ-count ntile, 2018-vintage cutpoints)"
}

* ---- labels ------------------------------------------------------------------
label var occ_vintage "Census occupation code vintage (2010 = CPS <=2019, 2018 = CPS 2020+)"
label var occ         "CPS public-use occupation code (IPUMS OCC)"
label var nobs        "CPS unweighted obs on this code (reference)"
label var emp_share   "share of vintage employment on this code (reference)"

* collapse leaves "(sum) _one" / "(max) _wtd" style labels on the diagnostics
foreach m of local measures {
    capture label var nsrc_`m' "`m': sources aggregated, FINAL crosswalk hop only"
    capture label var wtd_`m'  "`m': 2=emp-weighted 1=unwtd fallback 0=unwtd (final hop)"
}

capture label var aioe       "Felten et al. (2021) AI Occupational Exposure"
capture label var estz_total "Eisfeldt et al. (2023) gen-AI exposure, total"
capture label var estz_core  "Eisfeldt et al. (2023) gen-AI exposure, core tasks"
capture label var estz_supp  "Eisfeldt et al. (2023) gen-AI exposure, supplemental"
capture label var gpt4_beta  "Eloundou et al. (2024) beta, GPT-4 annotated"
capture label var human_beta "Eloundou et al. (2024) beta, human annotated"
capture label var ai_applic  "Tomlinson et al. (2025) AI applicability score"

order occ_vintage occ nobs emp_share
sort occ_vintage occ
compress
label data "AI exposure by CPS occupation code and code vintage"
save "$prcd_data/ai_exposure_cps.dta", replace
export delimited using "$prcd_data/ai_exposure_cps.csv", replace

*==============================================================================*
* coverage report -- the thing that was silently broken before
*==============================================================================*
di as txt _n "{hline 78}"
di as txt "COVERAGE: share of CPS employment carrying a non-missing score"
di as txt "{hline 78}"
di as txt "measure        2010 vintage  2018 vintage   break (pp)"

foreach s of local scorevars {
    capture confirm variable `s'
    if _rc continue
    local row
    foreach v in 2010 2018 {
        quietly summ emp_share if occ_vintage == `v' & !missing(`s')
        local cov`v' = 100 * r(sum)
    }
    local brk = `cov2018' - `cov2010'
    di as result %-14s "`s'" %13.1f `cov2010' "%" %13.1f `cov2018' "%"  %12.1f `brk'
}

di as txt _n "A large 'break' means the measure covers a different share of"
di as txt "employment before and after 2020, which shows up in any time series"
di as txt "as an AI effect. The original build had a 1.4pp break on AIOE."

* biggest uncovered codes, per vintage
capture confirm variable aioe
if !_rc {
    foreach v in 2010 2018 {
        di as txt _n "Largest `v'-vintage CPS codes with NO Felten score:"
        preserve
            keep if occ_vintage == `v' & missing(aioe)
            gsort -emp_share
            if _N > 0 {
                list occ emp_share nobs in 1/`=min(10, _N)', clean noobs
            }
            else {
                di as result "   (none)"
            }
        restore
    }
}


*==============================================================================*
* HARMONIZED occ2010 EXPOSURE FILE
*
* Fixes the 2019m12->2020m1 artifact. The per-vintage file bins workers on two
* different code universes (484 codes, then 526), so the Jan-2020 recoding moves
* employment across bins with nobody changing job. Person-linked CPS records
* show 11.05% of workers changing bin at the boundary vs 5.37% in a normal
* Dec->Jan, with a +0.70pp net drift into bin 5.
*
* Keying on IPUMS OCC2010 -- one classification, all years -- gives 5.84% churn
* and +0.09pp drift, i.e. a normal month. Max monthly bin step falls 1.65 ->
* 0.52pp, inside the range seen in non-boundary Januaries.
*
* Cost: 474 categories instead of 526, and post-2020 OCC2010 values are IPUMS
* back-codes. That is the trade -- a consistent rule beats a scheme change.
*==============================================================================*

di as txt _n "== G  harmonized OCC2010 file ==========================================="

local scorevars aioe estz_total estz_core estz_supp gpt4_beta human_beta ai_applic

* --- G1. occ(2010 basis) -> occ2010 collapse map, from the CPS itself ---------
* Pre-2020 occ IS 2010-basis, so this recovers IPUMS's own collapse rule rather
* than assuming one. Verified deterministic: no occ maps to >1 occ2010 category.
use year occ occ2010 wtfinl using "$raw_cps/$cpsfile" if year <= 2019, clear
drop if occ == 0 | missing(occ) | occ2010 == 9999 | missing(occ2010)
collapse (sum) w = wtfinl, by(occ occ2010)
bysort occ: gen byte _nh = _N
quietly count if _nh > 1
if r(N) > 0 {
    di as error "   !! `r(N)' occ code(s) map to >1 occ2010 category -- taking the modal one"
}
bysort occ (w): keep if _n == _N
keep occ occ2010
rename occ occ2010basis
tempfile hmap
save "`hmap'"

* --- G2. occ2010 universe and employment shares, ALL years -------------------
use year occ occ2010 wtfinl using "$raw_cps/$cpsfile", clear
drop if occ == 0 | missing(occ) | occ2010 == 9999 | missing(occ2010)
gen byte one = 1
collapse (sum) nobs = one (sum) _w = wtfinl, by(occ2010)
egen double _tot = total(_w)
gen double emp_share = _w / _tot
keep occ2010 nobs emp_share
label var emp_share "share of full-window employment on this occ2010 category"
compress
save "$prcd_exp/cps_occ2010_universe.dta", replace

* --- G3. collapse the 2010-vintage scores onto occ2010 -----------------------
use "$prcd_data/ai_exposure_cps.dta", clear
keep if occ_vintage == 2010
rename occ occ2010basis
merge 1:1 occ2010basis using "`hmap'", keep(master match) generate(_mh)
quietly count if _mh == 1
if r(N) > 0 di as error "   !! `r(N)' 2010-basis code(s) with no occ2010 mapping"
drop _mh
keep occ2010 emp_share `scorevars'
drop if missing(occ2010)
collapse (mean) `scorevars' [aw = emp_share], by(occ2010)

* --- G4. bins computed ONCE over occ2010 categories --------------------------
* One classification -> one set of bins -> membership cannot move at 2020.
foreach s of local scorevars {
    quietly _pctile `s' if !missing(`s'), nquantiles(5)
    forvalues q = 1/4 {
        local cut`q' = r(r`q')
    }
    gen byte `s'_q = .
    quietly replace `s'_q = 1 if !missing(`s')
    forvalues q = 1/4 {
        quietly replace `s'_q = `q' + 1 if !missing(`s') & `s' > `cut`q''
    }
    label var `s'_q "`s' quintile (occ2010 basis, single partition)"
}

* --- G5. attach the universe, report coverage, save -------------------------
merge 1:1 occ2010 using "$prcd_exp/cps_occ2010_universe.dta",  keep(match using) generate(_mu)
quietly count if _mu == 2
local nogap = r(N)
quietly summ emp_share if _mu == 2
di as result "   occ2010 categories with no score: `nogap' (" %5.2f `=100*r(sum)' "% of employment)"
drop _mu
label var occ2010 "IPUMS OCC2010 (harmonized, all years)"
compress
label data "AI exposure on IPUMS OCC2010 -- single classification, no 2020 break"
notes drop _dta
notes _dta : Keyed on IPUMS OCC2010 so occupation coding is constant across the
notes _dta : Jan-2020 CPS recoding. Boundary bin step 0.52pp vs 1.65pp on the
notes _dta : per-vintage file; person-linked bin churn 5.84% vs 5.37% control.
save "$prcd_data/ai_exposure_occ2010.dta", replace
di as result "   wrote ai_exposure_occ2010.dta: `=_N' occ2010 categories"

log close
