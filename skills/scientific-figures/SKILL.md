---
name: scientific-figures
description: Use when creating or editing scientific / matplotlib figures (PDE solution fields, radial spectra, multi-panel review/one-pager figures, dose-response or sweep plots) that another person will read cold. Enforces cold-reader clarity, GridSpec layout (no overlap), log-log for power-laws, mathtext for equations, descriptive labels, provenance in the header, and a fast generate/replot split.
---

# Scientific figures that read cold

A figure for a mentor/reviewer/paper is read with **no conversation context**. Optimize for the
cold reader: every panel says what it is, every axis is labeled, every abbreviation is keyed, and
the headline takeaway is visible at a glance.

## The cold-reader test (run before saving)
Imagine someone who wasn't in the conversation opens the PNG. Can they answer, from the figure alone:
- **What is this?** (PDE name / quantity, and which sample/case)
- **What produced it?** (governing equation + the parameter values — the condition vector)
- **What am I looking at in each panel?** (descriptive titles, not internal shorthand)
- **What's the takeaway number?** (key metric/slope, on the figure)
If any answer requires outside context, fix the figure.

## Layout — use GridSpec + constrained_layout, never hacks
- Create with `fig = plt.figure(figsize=(w, h), constrained_layout=True)` and
  `gs = GridSpec(rows, cols, figure=fig, height_ratios=[...])`. Add axes with `fig.add_subplot(gs[r, c])`
  and span with `gs[r, :]`.
- **NEVER** build a spanning/irregular panel by `ax.remove()` + a manual `fig.add_subplot(2,1,2)` —
  `constrained_layout` can't manage the re-added axis and titles overlap. Use GridSpec spanning.
- Keep panel titles short (1 line, or 2 short lines). Put long context in the suptitle or a footer,
  where constrained_layout reserves space.
- Set figsize at creation; give extra height when the suptitle has several lines.
- Use the object-oriented API (`ax.imshow`, `ax.loglog`), not `plt.`-state calls, in scripts.

## Never let text overflow
Long metric/parameter lines run off the page. Wrap to a few items per line, use short labels, and
point overflow to a data file (e.g. `(full panel in sample_summary.json)`). Verify by *looking* at
the rendered PNG, not just by running the code.

## Axes — pick the scale that linearizes the thing you're measuring
- **Power-law decay** (shocks, sharp fields, `1/k^p` spectra): **log-log**. The decay is then a
  straight line and its slope is the exponent. Always log-log when the reader cares about the slope.
- **Exponential decay** (smooth/analytic, `e^{-ak}`): **semi-log** (log-y, linear-x) → straight line.
- If you quote a fitted slope/rate, **draw it**: overlay a dashed reference line at the fit and put
  the value in the legend (`label=f"HF decay slope ~ {slope:.1f}"`), so it's on the figure, not just
  in the terminal.
- Mark physically meaningful wavenumbers/cutoffs (Nyquist of a grid, a model's mode cutoff) with an
  `axvline` + a shaded `axvspan` for the truncated band.

## Math — use mathtext (no LaTeX install needed)
- Render equations/symbols with `$...$` mathtext: `r"$\partial_t c = M\,\nabla^2(c^3 - c - \varepsilon^2\,\nabla^2 c)$"`.
- Map variable names to symbols consistently (`eps`→`$\varepsilon$`, `gamma`→`$\gamma$`,
  ratios→`$p_{TL}/p_{TR}$`) so the header math matches the equation. Mixed plain+`$...$` in one
  string is fine.

## Fields / images
- Show low-resolution fields at **native resolution with `interpolation="nearest"`** so a coarse
  grid looks genuinely blocky — make the resolution difference visible, don't hide it with smoothing.
- Use a **shared color scale** (`vmin/vmax`) across panels meant to be compared.
- Prefer perceptually-uniform colormaps (`viridis`); diverging (`coolwarm`) for signed residuals,
  symmetric about 0.
- Label rows/columns by role with a y-label on the first panel (e.g. "solution field (native
  resolution)" vs "error field (on shared HF grid)").

## Labels — descriptive, keyed, provenance-bearing
- **Descriptive titles**, deck/PowerPoint style: "Error between LF (32×32 grid) and HF (128×128 grid)",
  not "HF − LF".
- **Avoid ambiguous abbreviations.** Don't use "MF" for mid-fidelity when the project is about
  *multi-fidelity*; use "IF" (intermediate). Always include a key: `LF / IF / HF = low / intermediate
  / high fidelity`.
- **Show provenance** in the header: the governing equation + the sample's parameter values.
- **Curate metrics**: show the 3–4 most meaningful spelled out; point to a file for the full set.

## Separate generation from plotting (fast iteration)
- Save the expensive solve/sim output (HDF5/NPZ) once; render figures from the saved data.
- Provide a `--replot` / cache path so layout tweaks re-render in seconds without re-solving.
- Iterate on layout where you can *see* the PNG (locally); run heavy generation where the compute is.
- Plotting must never crash a generation run — wrap figure calls in try/except; guard against NaN/
  empty data before `polyfit`/`log`.

## Worked example
`your_research_package/src/your_research_package/common/visualize.py` in your-research-repo repo (your-research-project review one-pager) applies all of the above:
native-resolution LF/IF/HF field row, descriptive "Error between …" panels, mathtext PDE + condition
vector header, curated metrics, log-log spectrum with an annotated slope, and a `generate.py --replot`
path. Mirror it for new figure types.

## Pre-save checklist
- [ ] Cold-reader test passes (what / from what / each panel / takeaway).
- [ ] No overlapping titles (GridSpec, looked at the PNG).
- [ ] Nothing runs off the page.
- [ ] Right axis scale; fitted slopes drawn + in legend.
- [ ] Equations/symbols in mathtext; abbreviations keyed.
- [ ] Low-res fields shown blocky; shared color scale where comparing.
- [ ] Figure renders from saved data (re-runnable without re-solving).
