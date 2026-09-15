# Tuning threshold selection

This table is generated from committed tuning-only raw rankings. It reproduces the selection calculation; it does not establish the chronology of the original holdout run.

Candidates evaluated: **15**; qualifying: **4**.

| Evidence bytes | Top score | Margin | Conversions | Precision | Useful-code coverage | Dedicated negative conversions | Qualifies |
|---:|---:|---:|---:|---:|---:|---:|:---:|
| 20 | 0.20 | 0.20 | 122 | 94.26% | 94.26% | 5/603 | no |
| 20 | 0.20 | 0.30 | 105 | 99.05% | 85.25% | 0/603 | yes |
| 20 | 0.20 | 0.40 | 98 | 98.98% | 79.51% | 0/603 | no |
| 20 | 0.30 | 0.20 | 122 | 94.26% | 94.26% | 5/603 | no |
| 20 | 0.30 | 0.30 | 105 | 99.05% | 85.25% | 0/603 | yes |
| 20 | 0.30 | 0.40 | 98 | 98.98% | 79.51% | 0/603 | no |
| 20 | 0.40 | 0.20 | 111 | 99.10% | 90.16% | 0/603 | yes |
| 20 | 0.40 | 0.30 | 105 | 99.05% | 85.25% | 0/603 | yes |
| 20 | 0.40 | 0.40 | 98 | 98.98% | 79.51% | 0/603 | no |
| 20 | 0.50 | 0.20 | 97 | 98.97% | 78.69% | 0/603 | no |
| 20 | 0.50 | 0.30 | 97 | 98.97% | 78.69% | 0/603 | no |
| 20 | 0.50 | 0.40 | 93 | 98.92% | 75.41% | 0/603 | no |
| 20 | 0.60 | 0.20 | 80 | 98.75% | 64.75% | 0/603 | no |
| 20 | 0.60 | 0.30 | 80 | 98.75% | 64.75% | 0/603 | no |
| 20 | 0.60 | 0.40 | 79 | 98.73% | 63.93% | 0/603 | no |

Selected: `20 / 0.40 / 0.20` with 90.16% useful-code coverage.
