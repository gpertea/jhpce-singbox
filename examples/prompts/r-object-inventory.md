# Task: inventory R objects under /dcs04/lieber/marmaypag

You are running inside ai-singbox: everything under /dcs04/lieber is read-only
except `/dcs04/lieber/marmaypag/data-inventory`, which is where all your output goes.
Use `$MYSCRATCH` or `/tmp` for scratch files. Slurm is not available; work within this
session's CPUs and memory (`nproc`, `free -g`).

## Goal

A table describing every R object file under `/dcs04/lieber/marmaypag`, plus a short
per-project summary, so that people can find datasets without opening them.

## Files to look for

- `*.rds`, `*.RDS`, `*.rda`, `*.RData`, `*.Rdata`
- HDF5-backed SummarizedExperiment folders (`se.rds` + `assays.h5`, written by
  `HDF5Array::saveHDF5SummarizedExperiment`), and standalone `*.h5` / `*.h5ad`
- Skip `.snakemake`, `.git`, `renv/library`, and any folder named `tmp` or `cache`.

## Method

1. List candidate files first with `find` (record path, size, mtime) into
   `data-inventory/files.tsv`. Do not open anything yet.
2. Write an R script `data-inventory/scripts/inspect_one.R` that takes one file path and
   prints one JSON line: path, size_bytes, mtime, top-level class(es), and when they
   apply: dim, assayNames, rowData/colData column names, number of columns per sample
   column, reducedDimNames, altExpNames, metadata names, genome info, object.size.
   For `.rda/.RData`, list every object in the file with the same fields.
3. Run it on one file per R process, with a timeout (`timeout 600`), and skip files
   larger than the session's free memory divided by 3 (record them as `skipped:size`).
   Append each JSON line to `data-inventory/objects.jsonl`. Make the run resumable:
   skip paths already in `objects.jsonl`.
4. Record failures as JSON lines with an `error` field; never retry endlessly.
5. Convert `objects.jsonl` to `data-inventory/objects.tsv`, and write
   `data-inventory/SUMMARY.md` with one section per top-level project folder: number of
   objects, total size, classes found, the largest objects, and notable gaps.

## Rules

- Never modify, move, or re-save the inspected files (they are read-only anyway).
- Keep all scripts you write under `data-inventory/scripts/` so the run can be repeated.
- Start with one project folder, show me the result, then continue with the rest.
