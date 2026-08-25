

*==============================================================================*
*
* PURPOSE   Settings and helper programs shared by every script in code/.
*           Included, not run: both 01_build_cps_exposure.do and
*           02_boundary_diagnostic.do start with `include 0_config.do'.
*
* CONTAINS  paths and globals            (below)
*           _read_oews                   one OEWS national file -> soc + emp_wt
*           soc_census_map               detailed SOC -> Census code, 1:1 on SOC
*           _xwalk_score                 move SCORES between coding schemes
*
* NOTE      Nothing here reads or writes project data on its own. Edit the
*           globals to point the pipeline at a different extract or window;
*           edit the programs only with a rerun and a diff of the outputs.
*
*==============================================================================*

*------------------------------------------------------------------------------*
* Paths. base_dir is derived from the CURRENT DIRECTORY, so every script must be
* run from code/ -- which is what run_all.sh does (`cd "$(dirname "$0")"`).
* Launching a script from the repo root instead silently resolves every path one
* level too high and the first import fails.
*------------------------------------------------------------------------------*
global base_dir "`c(pwd)'/../"
global raw_data "$base_dir/data/raw/"
global prcd_data "$base_dir/data/processed/"
global output "$base_dir/output"
global fig "$output/figures/"

* raw inputs, by source. None of these are in the git repo: they ship with the
* replication bundle. See README.md for where to download it.
global raw_cps "$raw_data/cps/"
global raw_xwlk "$raw_data/crosswalks/"
global raw_oews "$raw_data/oews/"
global raw_aiexp "$raw_data/ai_exposure/"

* derived data. intermediate_exposure/ holds one checkpoint per crosswalk hop,
* so any single hop can be audited without rerunning the whole build.
global prcd_exp "$prcd_data/intermediate_exposure/"

*------------------------------------------------------------------------------*
* The CPS extract. Swapping extracts means changing this line -- and then
* rebuilding, because step C derives the occupation universe from whatever this
* points at, and step D CONSTRUCTS the 2010 collapse map from that universe. A
* different extract can therefore change the crosswalk, not just the counts.
*------------------------------------------------------------------------------*
global cpsfile "cps_00029.dta"

*------------------------------------------------------------------------------*
* The analysis window, set once and used everywhere: step C's universe, both
* step-G reads, the boundary diagnostic, and the emp_share_* variable labels.
* Two constraints worth knowing before widening or narrowing it:
*   - it needs enough years EITHER SIDE of Jan 2020 for both code vintages to be
*     populated; 5 years each is comfortable
*   - a code that is genuinely rare and happens not to appear inside the window
*     is treated as "not a CPS code" and its exposure is routed elsewhere, so a
*     short window quietly changes the collapse map (see step C)
* The extract currently runs past cps_yr_max; every occupation code observed in
* the excluded years is already in the universe, so nothing is being dropped.
*------------------------------------------------------------------------------*
global cps_yr_min = 2015
global cps_yr_max = 2024


*==============================================================================*
* _read_oews -- one OEWS national workbook -> one row per detailed SOC, with the
* employment figure used as an aggregation weight everywhere downstream.
*
* SYNTAX
*   _read_oews "path/to/national_MYYYY_dl.xlsx", socvar(name) out(filename)
*
* Three properties of the source files this has to absorb:
*   - the group-indicator column is O_GROUP in 2019+ vintages and OCC_GROUP in
*     older ones. Both are accepted; anything else is a hard error, because
*     silently keeping the aggregate rows would double-count employment.
*   - only "detailed" rows are kept. The file also carries total, major, minor
*     and broad rows, which are sums of the detailed ones.
*   - TOT_EMP is text: it carries thousands separators, and "*" / "**" mark
*     suppressed cells. real() turns those into missing, which is what we want --
*     a suppressed cell is unknown employment, not zero employment.
*==============================================================================*
capture program drop _read_oews
program define _read_oews
    syntax anything(name=path), SOCVAR(name) OUT(string)

    quietly {
        import excel using `path', firstrow clear allstring
        rename *, upper

        * group indicator: O_GROUP (2019+) or OCC_GROUP (older)
        capture confirm variable O_GROUP
        if _rc {
            capture confirm variable OCC_GROUP
            if _rc {
                noisily di as error  "   _read_oews: no O_GROUP / OCC_GROUP column in `path'"
                exit 111
            }
            rename OCC_GROUP O_GROUP
        }

        foreach v in OCC_CODE TOT_EMP {
            capture confirm variable `v'
            if _rc {
                noisily di as error "   _read_oews: no `v' column in `path'"
                exit 111
            }
        }

        keep OCC_CODE O_GROUP TOT_EMP

        * detailed SOC rows only: drop total / major / minor / broad aggregates
        replace O_GROUP = lower(strtrim(O_GROUP))
        keep if O_GROUP == "detailed"

        gen str7 `socvar' = strtrim(OCC_CODE)
        keep if ustrregexm(`socvar', "^[0-9][0-9]-[0-9][0-9][0-9][0-9]$")

        * TOT_EMP carries thousands separators; "*" / "**" mean suppressed,
        * which real() turns into missing -- exactly what we want
        replace TOT_EMP = subinstr(TOT_EMP, ",", "", .)
        gen double emp_wt = real(TOT_EMP)

        keep `socvar' emp_wt
        collapse (sum) emp_wt, by(`socvar')
        * collapse turns all-missing groups into 0; put them back to missing so
        * xwalk_score treats them as "no weight" rather than "zero workers"
        replace emp_wt = . if emp_wt <= 0

        label var emp_wt "OEWS national employment (aggregation weight)"
        compress
        save "`out'", replace
    }
end


*==============================================================================*
* soc_census_map -- detailed SOC -> Census occupation code, 1:1 on SOC
*
* Census SOC patterns come in three flavours, all covered by one prefix rule:
*   17-2151  exact        -> matches at length 7
*   29-1020  broad group  -> trailing 0 is filler, matches at length 6
*   17-301X  wildcard     -> trailing X is filler, matches at length 6
* For each pattern take the longest prefix that (a) has only X/0 after it and
* (b) matches a real SOC. Then, per SOC, keep the most specific claimant: "X"
* means the REMAINING codes in a group, so an explicitly named Census code
* (length 7) must beat a wildcard (length 5-6) claiming the same SOC.
*
* That per-SOC step is the entire fix. _expand_soc ranked prefixes within a
* pattern but never across patterns, so residual "Other ..." codes swallowed
* their named siblings -- 171 SOCs on the 2018 side, 6.5% of employment.
*==============================================================================*
capture program drop soc_census_map
program define soc_census_map
    syntax , ID(name) PAT(name) MASTER(string) OUT(string)
    
    quietly {
        keep `id' `pat'
        replace `pat' = strtrim(upper(`pat'))
        drop if missing(`id') | inlist(`pat', "", "NONE", ".")
        duplicates drop
        levelsof `id', local(_i0)
        * patterns x detailed SOC
        cross using "`master'"
        gen byte k = .
        forvalues j = 7(-1)3 {
            replace k = `j' if missing(k) & ustrregexm(substr(`pat', `j' + 1, .), "^[X0]*$") & substr(soc_full, 1, `j') == substr(`pat', 1, `j')
        }
        drop if missing(k)
        * most specific claimant
        bysort soc_full: egen byte _best = max(k)
        keep if k == _best
        * A tie here should be impossible: the Census classification is a
        * partition of detailed SOCs, so two patterns claiming the same SOC at
        * equal specificity means the source list is inconsistent or the
        * wildcard/broad-group expansion mis-parsed it. Report it rather than
        * letting the tie-break below silently pick one, and resolve it the way
        * step D resolves its ambiguities -- by hand, in an override file.
        bysort soc_full `id': gen byte _fid = (_n == 1)
        bysort soc_full: egen int _nid = total(_fid)
        quietly count if _nid > 1
        if r(N) > 0 {
            noisily di as error "   !! `r(N)' row(s) on SOC(s) with >1 equally-specific Census claimant -- inspect, do not ignore"
            noisily list soc_full `id' `pat' k if _nid > 1, clean noobs
        }
        drop _fid _nid

        * deterministic tie-break (fallback only; see the check above)
        bysort soc_full (`id'): keep if _n == 1

        keep soc_full `id'
        order soc_full `id'
        isid soc_full
        compress
        save "`out'", replace

        levelsof `id', local(_i1)
        local d = `: word count `_i0'' - `: word count `_i1''
        noisily di as result "   soc_census_map: `=_N' pairs, 1:1 on SOC" _n "`d' Census"
    }
end

* xwalk_score -- move occupation-level SCORES across coding schemes
*==============================================================================*
* Crosswalk one or more score variables from a source code scheme to a target
* code scheme, treating the scores as INTENSIVE quantities.
*
*   one source -> many targets : score is COPIED to each target
*                                (an exposure index is not a headcount; it does
*                                 not get divided up)
*   many sources -> one target : score is the EMPLOYMENT-WEIGHTED MEAN
*                                (falls back to an unweighted mean if no
*                                 employment file is supplied, or if every
*                                 contributing source has missing employment)
*
* SYNTAX
*   xwalk_score scorevars, source(varname) target(varname) ///
*       xwalk(filename) [empfile(filename)]
*
*   Data in memory must contain source() plus the score variables.
*   xwalk()   .dta with source() and target(); duplicates are fine.
*   empfile() .dta with source() and a variable named emp_wt.
*
* Leaves in memory: one row per target(), plus the score variables, plus
*   _nsrc     number of source codes that contributed
*   _wtd      2 every contributing source had OEWS employment, so the target is
*               a genuine employment-weighted mean
*             1 at least ONE contributor lacked employment: the whole group
*               falls back to an UNWEIGHTED mean rather than assigning the
*               unmeasured sources a near-zero weight
*             0 no employment file was supplied at all
*             (note 1 means "not weighted", which is the opposite of what this
*              header said while the flag was binary)
*==============================================================================*
capture program drop _xwalk_score
program define _xwalk_score
    syntax varlist(numeric), SOURCE(name) TARGET(name) Xwalk(string) [EMPfile(string)]

    confirm file "`xwalk'"
    if "`empfile'" != "" confirm file "`empfile'"

    tempfile scores
    tempvar totemp

    quietly {
        * ---- collapse to one row per source code -----------------------------
        keep `source' `varlist'
        drop if missing(`source')
        collapse (mean) `varlist', by(`source')
        save "`scores'"

        * ---- expand along the crosswalk -------------------------------------
        use "`xwalk'", clear
        keep `source' `target'
        drop if missing(`source') | missing(`target')
        duplicates drop
        merge m:1 `source' using "`scores'", keep(match) nogenerate

        if _N == 0 {
            noisily di as error "xwalk_score: no source codes matched the crosswalk"
            exit 459
        }

        * ---- employment weights ---------------------------------------------
        gen byte _wtd = 0
        if "`empfile'" != "" {
            merge m:1 `source' using "`empfile'", keep(master match) nogenerate
            cap confirm variable emp_wt
            if _rc {
                noisily di as error "xwalk_score: empfile() has no variable emp_wt"
                exit 111
            }
            replace emp_wt = . if emp_wt <= 0

            * a group is fully weighted only if EVERY contributor has employment
            bysort `target': egen double `totemp'  = total(emp_wt)
            bysort `target': egen byte   _nmiss    = total(missing(emp_wt))
            replace _wtd = 2 if `totemp' > 0 & !missing(`totemp') & _nmiss == 0
            replace _wtd = 1 if `totemp' > 0 & !missing(`totemp') & _nmiss > 0
            * partially-weighted group: fall back to an unweighted mean rather
            * than assigning a near-zero weight to the unmeasured contributors
            bysort `target': replace emp_wt = 1 if _nmiss > 0
            replace emp_wt = 1 if missing(emp_wt)
            drop `totemp' _nmiss
        }
        else {
            gen double emp_wt = 1
        }

        * ---- aggregate to target --------------------------------------------
        gen byte _one = 1
        collapse (mean) `varlist' (max) _wtd (sum) _nsrc = _one [aw = emp_wt],  by(`target')

        order `target' _nsrc _wtd
        sort `target'
    }
end
