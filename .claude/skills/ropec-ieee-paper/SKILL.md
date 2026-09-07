---
name: ropec-ieee-paper
description: This skill should be used when the user asks to write, draft, fill, or update the ROPEC 2026 IEEE conference paper for this project, mentions "el paper", "el documento científico", "the IEEE paper", "juarezcruzog_progDelfin_ROPEC2026LatexTemplate.tex", "Paper/ROPEC2026LatexTemplateKit", or wants the project's technical findings (README.md, PROGRESO.md, resumen_tecnico_de_la_investigacion.md) turned into a submittable IEEE conference paper in English.
---

# ROPEC 2026 IEEE paper for progDelfin_iPXE

Turns this project's Spanish technical documentation into an English IEEE
conference paper (ROPEC 2026 format, IEEEtran two-column) by editing the
existing LaTeX template in place. Never generate a brand-new template — the
official ROPEC header/footer/copyright block in the `.tex` file must survive
untouched.

## Source of truth (read before writing prose)

Read these, in this order, every time this skill runs — they are the
project's own record and always more current than any prior paper draft:

1. `resumen_tecnico_de_la_investigacion.md` (repo root) — already-condensed
   Spanish summary: problem statement, objectives, methodology, architecture,
   findings, results, future work. This is the fastest path to the paper's
   structure.
2. `PROGRESO.md` (repo root) — full chronological bug/fix log ("Bitácora de
   intentos"), the primary source for concrete technical detail (exact bugs,
   root causes, fixes, live-verification steps) that make the paper
   convincing to reviewers instead of a vague overview.
3. `README.md` (repo root) — architecture diagrams, boot chain, requirements,
   repo structure. Source for the system-architecture section and any figure
   description.

Translate and rewrite into scientific English — do not paste Spanish prose
translated verbatim sentence-by-sentence; compress into IEEE-register
technical writing (passive/impersonal voice where idiomatic, precise
terminology, no first-person "we" is required but is acceptable and common in
IEEE conference papers).

## Target file and hard constraints

Target: `Paper/ROPEC2026LatexTemplateKit/juarezcruzog_progDelfin_ROPEC2026LatexTemplate.tex`

- **Language:** English only (the ROPEC template's own guidance text is
  English; body content must be too).
- **Length: no more than 6 pages** when typeset with the given `IEEEtran.cls`
  in `conference` mode, two-column, including figures, tables, and
  references. Keep this budget in mind while drafting (see "Page budget"
  below) — this is a hard constraint the user stated explicitly.
- **Keep untouched:** `\documentclass[conference]{IEEEtran}`, the package
  preamble, the `\fancypagestyle{firststyle}` / `\fancyhf` ROPEC header-footer
  block (conference name, copyright notice, DOI-style string), and
  `\hyphenation{...}`. These are conference-supplied boilerplate, not
  placeholder text — do not edit or remove them.
- **Must remove entirely:** every instructional/placeholder paragraph
  IEEE ships in the skeleton — the "Ease of Use", "Prepare Your Paper Before
  Styling", "Abbreviations and Acronyms", "Units", "Equations",
  "LaTeX-Specific Advice", "Some Common Mistakes", "Authors and Affiliations",
  "Identify the Headings", "Figures and Tables" boilerplate subsections, the
  placeholder `\cite{b1}`–`\cite{b7}` demo sentences, the sample table/figure
  (`fig1.png`, `Table Type Styles`) unless replaced with a real
  project figure/table, and the final `\color{red}` "IEEE conference
  templates contain guidance text..." disclaimer paragraph. None of this may
  survive into the submitted draft.
- **Duplicated sections in the skeleton:** the template file has `Acknowledgment`
  and the bibliography-intro prose duplicated/out of order (an `\section*{Acknowledgment}`
  appears twice, `References` demo prose sits before `\section{Conclusions}`).
  Consolidate into one clean, correctly ordered structure: Introduction →
  body sections → Conclusion → Acknowledgment (optional, keep only if there is
  a real funding/thanks statement; otherwise delete the section entirely,
  don't leave a stub) → References (`thebibliography`, IEEE bracket style).

## Section plan (map source material → paper sections)

1. **Title** — descriptive, no symbols/math/footnote markers in the title
   itself per IEEE rule already noted in the template. Something naming the
   concrete contribution, e.g. "Full-Network Boot of HuronOS via iPXE:
   Kernel, Persistence, and Directive Enforcement Without Physical USB
   Media" — adapt, don't ship verbatim.
2. **Abstract** (150–200 words) — problem (USB-per-station exam OS deployment
   doesn't scale), approach (kernel/initrd rebuilt with network support,
   HTTP-based system fetch, directive/persistence sync layer), and headline
   result (full netboot to desktop validated in QEMU simulation and on a
   real-hardware pilot with a physical router and client laptop).
3. **Introduction** — exam/contest OS deployment problem for ICMP/OMI labs,
   why per-station USB media doesn't scale, research question, contribution
   bullets, paper roadmap sentence.
4. **Background / Root-Cause Analysis** — from `resumen_tecnico_de_la_investigacion.md`
   §2–3 and `PROGRESO.md` intentos 1–3: why naive approaches failed (initrd
   patch with no NIC driver at all; `sanboot`/iSCSI failing once the
   bootloader hands off to the kernel), and the actual root cause found in
   `huronOS-build-tools` (`NETWORK=false` build switch, not a kernel
   limitation).
5. **Methodology** — the iterative hypothesize → instrument (debug shells,
   static code reading, custom logs surviving `pivot_root`) → minimal
   additive fix (stacked `.hsl` layers, systemd drop-ins, `netboot=true`
   -gated branches) → live verification loop described in
   `resumen_tecnico_de_la_investigacion.md` §4. Emphasize that fixes were
   validated by live boot behavior, not static review, since several bugs
   were runtime-only.
6. **System Architecture** — simulation topology (dnsmasq+nginx+sync-server
   container, QEMU slaves) and the boot chain, condensed from `README.md`
   "Arquitectura"/"Cadena de arranque". One figure here is worth the page
   budget if a clean diagram can be produced (TikZ or a simple
   `\includegraphics` block diagram) — otherwise describe as an itemized
   sequence, do not keep the placeholder `fig1.png`/`Fig.~\ref{fig}` unless
   it is replaced by a real, relevant image.
7. **Implementation — the three additive patches** — `livekitlib`
   (`find_data_netboot()`, tmpfs event/contest, loop-over-FUSE fix), `hmm`
   (on-demand `.hsm` fetch, the 4 GiB `httpfs2` limit and the software-catalog
   split that works around it), `hnetsync` (push/pull persistence layer, the
   `system_has_just_booted()` 60 s-window bug and its fix). Keep this section
   dense and technical — it is the paper's main contribution.
8. **Real-Hardware Pilot** — from `PROGRESO.md` intento 13–14: Raspberry Pi
   master + MikroTik router + physical laptop, the non-iPXE factory firmware
   problem and its two-stage TFTP chainload fix (`snponly.efi`), the `ufw`
   silent-drop bug, and the entrypoint race-condition hardening. This section
   is what distinguishes the paper from a pure-simulation report — keep it.
9. **Results / Validation** — concrete, itemized, verifiable claims only
   (boot time ~2:30 min, directive enforcement confirmed live, persistence
   confirmed across a real power cycle, PXE boot to desktop confirmed on
   physical hardware). Do not state anything as validated that the source
   docs mark as still pending (site-allowlist and `hnetsync` on the physical
   laptop are explicitly pending in `PROGRESO.md` "Próximos pasos" — phrase
   these as future work, not results).
10. **Conclusion** — restate contribution and significance for ICMP/OMI-style
    exam labs; one sentence on generality beyond this specific distro if
    honestly supportable.
11. **Future Work** — from `PROGRESO.md` "Próximos pasos": boot-time
    optimization, `Event`-mode QEMU validation, persistence/allowlist
    verification on physical hardware, scaling to more physical stations.
12. **References** — IEEE bracket style in the existing `thebibliography`
    environment. Include at minimum: the official HuronOS build-tools repo,
    the directives example repo, and any genuinely relevant general
    references (netboot/PXE, AUFS/union filesystems, IEEE writing style
    guide already cited as `b7`) — replace the demo bibliography entries,
    don't leave Bessel-function/magnetism placeholders in a paper about
    network boot.

## Author block

Never invent co-authors, affiliations, or emails. The template ships 3 dummy
author blocks (`\IEEEauthorblockN{1st Given Name Surname}` etc.) — if the
real author/affiliation/email details are not already known from the
conversation, leave a single clearly-marked author entry with the best
available inference (e.g. name derivable from the `.tex` filename itself,
`juarezcruzog` → "Juárez Cruz, O. G.") and explicitly ask the user to confirm
or correct name spelling, department, institution, city/country, and email
before treating the paper as submission-ready. Do not silently ship guessed
institutional affiliation.

## Page budget (no local LaTeX toolchain available in this environment)

There is no `pdflatex`/`latexmk` in this sandbox to compile and check the
actual page count — budget by word count instead, and tell the user to
compile locally (they already have a working toolchain: the checked-in
`ROPEC2026LatexTemplate.pdf`/`.log`/`.aux`/`.synctex.gz` files prove a prior
successful local or Overleaf compile) and report the resulting page count
back so the draft can be trimmed if it runs long.

Rule of thumb for `IEEEtran` conference, two-column, 10 pt: roughly
900–1000 words of body text per column with light figure/table use, so
**~5000–5500 words total body text (excluding references) is a safe target
for a 6-page limit that includes the reference list.** Prefer trimming the
Background and Methodology narrative (condense to the essential causal
chain) before trimming Implementation or Real-Hardware Pilot — those two
sections are the paper's actual contribution.

After drafting, instruct the user to run, from
`Paper/ROPEC2026LatexTemplateKit/`:

```bash
pdflatex juarezcruzog_progDelfin_ROPEC2026LatexTemplate.tex
pdflatex juarezcruzog_progDelfin_ROPEC2026LatexTemplate.tex   # twice, for refs/TOC numbering
pdfinfo juarezcruzog_progDelfin_ROPEC2026LatexTemplate.pdf | grep Pages
```

and report back if it exceeds 6 pages so wording can be cut further.

## Verification checklist before declaring the draft done

- [ ] No leftover IEEE placeholder/instructional prose anywhere in the file
      (search for "This document is a model", "blindtext", "Given Name
      Surname", "Sample of a Table footnote", the red disclaimer paragraph).
- [ ] Only one `Acknowledgment` section (or none, if there is nothing genuine
      to acknowledge) and only one bibliography.
- [ ] Every `\cite{}` key resolves to a real, present `\bibitem`.
- [ ] Every claim in Results is traceable to something the source docs mark
      as actually verified live, not merely planned/pending.
- [ ] ROPEC header/footer (`firststyle` pagestyle, copyright/DOI string) and
      `\documentclass`/package preamble are unchanged from the original kit.
- [ ] Body is English throughout, including figure/table captions.
