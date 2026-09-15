# Language evaluation report

- Split: `holdout`
- Platform: `macos/aarch64`
- Profile: `release`
- Executable size: 759360 bytes
- Whole-process max RSS proxy: 8863744 bytes (/usr/bin/time)
- Cold first eligible inference: 1619500 ns
- Warm p50/p95/p99/max: 857208 ns/897083 ns/936416 ns/937208 ns

## Automatic-paste gate

- Conclusion: **pass**

## Aggregate metrics

| Metric | Raw | Rate |
|---|---:|---:|
| Total cases | 1334 | n/a |
| Eligible cases | 1333 | n/a |
| Useful-code cases | 125 | n/a |
| Eligible useful-code cases | 125 | n/a |
| Accepted cases | 211 | n/a |
| Accepted precision (accepted useful code / all accepted) | 105/211 | 49.76% (95% CI 43.08–56.45%) |
| Exact-label precision where defined | 105/105 | 100.00% (95% CI 96.47–100.00%) |
| Useful-code coverage | 105/125 | 84.00% (95% CI 76.58–89.40%) |
| Exact useful-code coverage | 105/125 | 84.00% (95% CI 76.58–89.40%) |
| Abstention | 1123/1334 | 84.18% (95% CI 82.13–86.04%) |
| Negative false conversions | 106/1209 | 8.77% (95% CI 7.30–10.50%) |
| Automatic paste conversions | 103 | n/a |
| Automatic paste precision | 102/103 | 99.03% (95% CI 94.70–99.83%) |
| Automatic paste useful-code coverage | 102/122 | 83.61% (95% CI 76.03–89.13%) |
| Dedicated prose/list/URL paste-negative conversions | 0/1203 | 0.00% (95% CI 0.00–0.32%) |

## Metrics by product surface

| Surface | Cases | Eligible | Useful | Eligible useful | Accepted precision | Exact-label precision | Useful coverage | Exact useful coverage | Abstention | Negative false conversions |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| fence | 3 | 3 | 2 | 2 | 66.67% (95% CI 20.77–93.85%) | 100.00% (95% CI 34.24–100.00%) | 100.00% (95% CI 34.24–100.00%) | 100.00% (95% CI 34.24–100.00%) | 0.00% (95% CI 0.00–56.15%) | 100.00% (95% CI 20.65–100.00%) |
| file | 3 | 2 | 1 | 1 | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 66.67% (95% CI 20.77–93.85%) | 0.00% (95% CI 0.00–65.76%) |
| paste | 1328 | 1328 | 122 | 122 | 49.28% (95% CI 42.54–56.04%) | 100.00% (95% CI 96.37–100.00%) | 83.61% (95% CI 76.03–89.13%) | 83.61% (95% CI 76.03–89.13%) | 84.41% (95% CI 82.36–86.26%) | 8.71% (95% CI 7.24–10.43%) |

## Metrics by content kind

| Kind | Cases | Eligible | Useful | Eligible useful | Accepted precision | Exact-label precision | Useful coverage | Exact useful coverage | Abstention | Negative false conversions |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| binary | 1 | 0 | 0 | 0 | n/a | n/a | n/a | n/a | 100.00% (95% CI 20.65–100.00%) | 0.00% (95% CI 0.00–79.35%) |
| code | 124 | 124 | 124 | 124 | 100.00% (95% CI 96.44–100.00%) | 100.00% (95% CI 96.44–100.00%) | 83.87% (95% CI 76.40–89.31%) | 83.87% (95% CI 76.40–89.31%) | 16.13% (95% CI 10.69–23.60%) | n/a |
| config-shaped | 1 | 1 | 0 | 0 | n/a | n/a | n/a | n/a | 100.00% (95% CI 20.65–100.00%) | 0.00% (95% CI 0.00–79.35%) |
| credential-shaped | 1 | 1 | 0 | 0 | 0.00% (95% CI 0.00–79.35%) | n/a | n/a | n/a | 0.00% (95% CI 0.00–79.35%) | 100.00% (95% CI 20.65–100.00%) |
| list | 401 | 401 | 0 | 0 | 0.00% (95% CI 0.00–3.70%) | n/a | n/a | n/a | 75.06% (95% CI 70.60–79.05%) | 24.94% (95% CI 20.95–29.40%) |
| log | 1 | 1 | 0 | 0 | n/a | n/a | n/a | n/a | 100.00% (95% CI 20.65–100.00%) | 0.00% (95% CI 0.00–79.35%) |
| malformed-code | 1 | 1 | 1 | 1 | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 0.00% (95% CI 0.00–79.35%) | n/a |
| markdown | 1 | 1 | 0 | 0 | 0.00% (95% CI 0.00–79.35%) | n/a | n/a | n/a | 0.00% (95% CI 0.00–79.35%) | 100.00% (95% CI 20.65–100.00%) |
| mixed | 1 | 1 | 0 | 0 | n/a | n/a | n/a | n/a | 100.00% (95% CI 20.65–100.00%) | 0.00% (95% CI 0.00–79.35%) |
| prose | 401 | 401 | 0 | 0 | 0.00% (95% CI 0.00–48.99%) | n/a | n/a | n/a | 99.00% (95% CI 97.46–99.61%) | 1.00% (95% CI 0.39–2.54%) |
| url | 401 | 401 | 0 | 0 | n/a | n/a | n/a | n/a | 100.00% (95% CI 99.05–100.00%) | 0.00% (95% CI 0.00–0.95%) |

## Metrics by input length

| Input bytes | Cases | Eligible | Useful | Eligible useful | Accepted precision | Exact-label precision | Useful coverage | Exact useful coverage | Abstention | Negative false conversions |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 020-079 | 1037 | 1036 | 1 | 1 | 0.94% (95% CI 0.17–5.15%) | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 89.78% (95% CI 87.79–91.48%) | 10.14% (95% CI 8.44–12.12%) |
| 080-255 | 297 | 297 | 124 | 124 | 99.05% (95% CI 94.80–99.83%) | 100.00% (95% CI 96.44–100.00%) | 83.87% (95% CI 76.40–89.31%) | 83.87% (95% CI 76.40–89.31%) | 64.65% (95% CI 59.05–69.86%) | 0.58% (95% CI 0.10–3.20%) |

## Confusion matrix

| Expected | Outcome | Count |
|---|---|---:|
| `__negative__:binary` | `__abstain__` | 1 |
| `__negative__:config-shaped` | `__abstain__` | 1 |
| `__negative__:credential-shaped` | `ini` | 1 |
| `__negative__:list` | `__abstain__` | 301 |
| `__negative__:list` | `markdown` | 100 |
| `__negative__:log` | `__abstain__` | 1 |
| `__negative__:markdown` | `markdown` | 1 |
| `__negative__:mixed` | `__abstain__` | 1 |
| `__negative__:prose` | `__abstain__` | 397 |
| `__negative__:prose` | `markdown` | 4 |
| `__negative__:url` | `__abstain__` | 401 |
| `go` | `__abstain__` | 10 |
| `go` | `go` | 1 |
| `html` | `html` | 1 |
| `javascript` | `javascript` | 10 |
| `json` | `json` | 10 |
| `python` | `python` | 11 |
| `ruby` | `ruby` | 10 |
| `rust` | `rust` | 10 |
| `shell` | `shell` | 11 |
| `sql` | `sql` | 10 |
| `swift` | `__abstain__` | 10 |
| `swift` | `swift` | 1 |
| `toml` | `toml` | 10 |
| `typescript` | `typescript` | 10 |
| `yaml` | `yaml` | 10 |

## Confusion pairs

| Pair | Count |
|---|---:|
| `__negative__:credential-shaped -> ini` | 1 |
| `__negative__:list -> markdown` | 100 |
| `__negative__:markdown -> markdown` | 1 |
| `__negative__:prose -> markdown` | 4 |
| `go -> __abstain__` | 10 |
| `swift -> __abstain__` | 10 |

## Detailed confusion cases

| Case | Surface | Kind | Expected | Outcome | Top score |
|---|---|---|---|---|---:|
| `holdout-list` | paste | list | `__negative__:list` | `markdown` | 0.401705 |
| `holdout-credential` | paste | credential-shaped | `__negative__:credential-shaped` | `ini` | 0.745027 |
| `holdout-markdown` | fence | markdown | `__negative__:markdown` | `markdown` | 0.839685 |
| `holdout-dedicated-paste-negative-0336` | paste | prose | `__negative__:prose` | `markdown` | 0.430346 |
| `holdout-dedicated-paste-negative-0345` | paste | prose | `__negative__:prose` | `markdown` | 0.420312 |
| `holdout-dedicated-paste-negative-0366` | paste | prose | `__negative__:prose` | `markdown` | 0.405882 |
| `holdout-dedicated-paste-negative-0456` | paste | prose | `__negative__:prose` | `markdown` | 0.409008 |
| `holdout-dedicated-paste-negative-0601` | paste | list | `__negative__:list` | `markdown` | 0.637275 |
| `holdout-dedicated-paste-negative-0604` | paste | list | `__negative__:list` | `markdown` | 0.619400 |
| `holdout-dedicated-paste-negative-0607` | paste | list | `__negative__:list` | `markdown` | 0.660438 |
| `holdout-dedicated-paste-negative-0610` | paste | list | `__negative__:list` | `markdown` | 0.688465 |
| `holdout-dedicated-paste-negative-0613` | paste | list | `__negative__:list` | `markdown` | 0.661146 |
| `holdout-dedicated-paste-negative-0616` | paste | list | `__negative__:list` | `markdown` | 0.719485 |
| `holdout-dedicated-paste-negative-0619` | paste | list | `__negative__:list` | `markdown` | 0.657468 |
| `holdout-dedicated-paste-negative-0622` | paste | list | `__negative__:list` | `markdown` | 0.755253 |
| `holdout-dedicated-paste-negative-0625` | paste | list | `__negative__:list` | `markdown` | 0.554869 |
| `holdout-dedicated-paste-negative-0628` | paste | list | `__negative__:list` | `markdown` | 0.772068 |
| `holdout-dedicated-paste-negative-0631` | paste | list | `__negative__:list` | `markdown` | 0.723305 |
| `holdout-dedicated-paste-negative-0634` | paste | list | `__negative__:list` | `markdown` | 0.654452 |
| `holdout-dedicated-paste-negative-0637` | paste | list | `__negative__:list` | `markdown` | 0.764374 |
| `holdout-dedicated-paste-negative-0640` | paste | list | `__negative__:list` | `markdown` | 0.722266 |
| `holdout-dedicated-paste-negative-0643` | paste | list | `__negative__:list` | `markdown` | 0.758646 |
| `holdout-dedicated-paste-negative-0646` | paste | list | `__negative__:list` | `markdown` | 0.745238 |
| `holdout-dedicated-paste-negative-0649` | paste | list | `__negative__:list` | `markdown` | 0.613491 |
| `holdout-dedicated-paste-negative-0652` | paste | list | `__negative__:list` | `markdown` | 0.762673 |
| `holdout-dedicated-paste-negative-0655` | paste | list | `__negative__:list` | `markdown` | 0.563541 |
| `holdout-dedicated-paste-negative-0658` | paste | list | `__negative__:list` | `markdown` | 0.745708 |
| `holdout-dedicated-paste-negative-0661` | paste | list | `__negative__:list` | `markdown` | 0.537832 |
| `holdout-dedicated-paste-negative-0664` | paste | list | `__negative__:list` | `markdown` | 0.402435 |
| `holdout-dedicated-paste-negative-0667` | paste | list | `__negative__:list` | `markdown` | 0.548773 |
| `holdout-dedicated-paste-negative-0670` | paste | list | `__negative__:list` | `markdown` | 0.588572 |
| `holdout-dedicated-paste-negative-0673` | paste | list | `__negative__:list` | `markdown` | 0.583393 |
| `holdout-dedicated-paste-negative-0676` | paste | list | `__negative__:list` | `markdown` | 0.530401 |
| `holdout-dedicated-paste-negative-0679` | paste | list | `__negative__:list` | `markdown` | 0.404471 |
| `holdout-dedicated-paste-negative-0682` | paste | list | `__negative__:list` | `markdown` | 0.503620 |
| `holdout-dedicated-paste-negative-0688` | paste | list | `__negative__:list` | `markdown` | 0.537889 |
| `holdout-dedicated-paste-negative-0691` | paste | list | `__negative__:list` | `markdown` | 0.660163 |
| `holdout-dedicated-paste-negative-0694` | paste | list | `__negative__:list` | `markdown` | 0.613617 |
| `holdout-dedicated-paste-negative-0697` | paste | list | `__negative__:list` | `markdown` | 0.715390 |
| `holdout-dedicated-paste-negative-0700` | paste | list | `__negative__:list` | `markdown` | 0.723703 |
| `holdout-dedicated-paste-negative-0703` | paste | list | `__negative__:list` | `markdown` | 0.681969 |
| `holdout-dedicated-paste-negative-0706` | paste | list | `__negative__:list` | `markdown` | 0.694385 |
| `holdout-dedicated-paste-negative-0709` | paste | list | `__negative__:list` | `markdown` | 0.609704 |
| `holdout-dedicated-paste-negative-0712` | paste | list | `__negative__:list` | `markdown` | 0.722339 |
| `holdout-dedicated-paste-negative-0715` | paste | list | `__negative__:list` | `markdown` | 0.597820 |
| `holdout-dedicated-paste-negative-0718` | paste | list | `__negative__:list` | `markdown` | 0.724421 |
| `holdout-dedicated-paste-negative-0721` | paste | list | `__negative__:list` | `markdown` | 0.652594 |
| `holdout-dedicated-paste-negative-0724` | paste | list | `__negative__:list` | `markdown` | 0.637081 |
| `holdout-dedicated-paste-negative-0727` | paste | list | `__negative__:list` | `markdown` | 0.661392 |
| `holdout-dedicated-paste-negative-0730` | paste | list | `__negative__:list` | `markdown` | 0.681779 |
| `holdout-dedicated-paste-negative-0733` | paste | list | `__negative__:list` | `markdown` | 0.650024 |
| `holdout-dedicated-paste-negative-0736` | paste | list | `__negative__:list` | `markdown` | 0.705455 |
| `holdout-dedicated-paste-negative-0739` | paste | list | `__negative__:list` | `markdown` | 0.625880 |
| `holdout-dedicated-paste-negative-0742` | paste | list | `__negative__:list` | `markdown` | 0.700766 |
| `holdout-dedicated-paste-negative-0745` | paste | list | `__negative__:list` | `markdown` | 0.553044 |
| `holdout-dedicated-paste-negative-0748` | paste | list | `__negative__:list` | `markdown` | 0.701711 |
| `holdout-dedicated-paste-negative-0751` | paste | list | `__negative__:list` | `markdown` | 0.666277 |
| `holdout-dedicated-paste-negative-0754` | paste | list | `__negative__:list` | `markdown` | 0.645632 |
| `holdout-dedicated-paste-negative-0757` | paste | list | `__negative__:list` | `markdown` | 0.636690 |
| `holdout-dedicated-paste-negative-0760` | paste | list | `__negative__:list` | `markdown` | 0.644895 |
| `holdout-dedicated-paste-negative-0763` | paste | list | `__negative__:list` | `markdown` | 0.661494 |
| `holdout-dedicated-paste-negative-0766` | paste | list | `__negative__:list` | `markdown` | 0.728085 |
| `holdout-dedicated-paste-negative-0769` | paste | list | `__negative__:list` | `markdown` | 0.668575 |
| `holdout-dedicated-paste-negative-0772` | paste | list | `__negative__:list` | `markdown` | 0.788462 |
| `holdout-dedicated-paste-negative-0775` | paste | list | `__negative__:list` | `markdown` | 0.550300 |
| `holdout-dedicated-paste-negative-0778` | paste | list | `__negative__:list` | `markdown` | 0.774532 |
| `holdout-dedicated-paste-negative-0781` | paste | list | `__negative__:list` | `markdown` | 0.720570 |
| `holdout-dedicated-paste-negative-0784` | paste | list | `__negative__:list` | `markdown` | 0.708649 |
| `holdout-dedicated-paste-negative-0787` | paste | list | `__negative__:list` | `markdown` | 0.760883 |
| `holdout-dedicated-paste-negative-0790` | paste | list | `__negative__:list` | `markdown` | 0.763032 |
| `holdout-dedicated-paste-negative-0793` | paste | list | `__negative__:list` | `markdown` | 0.756562 |
| `holdout-dedicated-paste-negative-0796` | paste | list | `__negative__:list` | `markdown` | 0.714666 |
| `holdout-dedicated-paste-negative-0799` | paste | list | `__negative__:list` | `markdown` | 0.612075 |
| `holdout-dedicated-paste-negative-0802` | paste | list | `__negative__:list` | `markdown` | 0.754574 |
| `holdout-dedicated-paste-negative-0805` | paste | list | `__negative__:list` | `markdown` | 0.642137 |
| `holdout-dedicated-paste-negative-0808` | paste | list | `__negative__:list` | `markdown` | 0.777315 |
| `holdout-dedicated-paste-negative-0811` | paste | list | `__negative__:list` | `markdown` | 0.656024 |
| `holdout-dedicated-paste-negative-0814` | paste | list | `__negative__:list` | `markdown` | 0.687598 |
| `holdout-dedicated-paste-negative-0817` | paste | list | `__negative__:list` | `markdown` | 0.688179 |
| `holdout-dedicated-paste-negative-0820` | paste | list | `__negative__:list` | `markdown` | 0.741060 |
| `holdout-dedicated-paste-negative-0823` | paste | list | `__negative__:list` | `markdown` | 0.693361 |
| `holdout-dedicated-paste-negative-0826` | paste | list | `__negative__:list` | `markdown` | 0.761081 |
| `holdout-dedicated-paste-negative-0829` | paste | list | `__negative__:list` | `markdown` | 0.696688 |
| `holdout-dedicated-paste-negative-0832` | paste | list | `__negative__:list` | `markdown` | 0.760150 |
| `holdout-dedicated-paste-negative-0835` | paste | list | `__negative__:list` | `markdown` | 0.612693 |
| `holdout-dedicated-paste-negative-0838` | paste | list | `__negative__:list` | `markdown` | 0.771139 |
| `holdout-dedicated-paste-negative-0841` | paste | list | `__negative__:list` | `markdown` | 0.688215 |
| `holdout-dedicated-paste-negative-0844` | paste | list | `__negative__:list` | `markdown` | 0.711903 |
| `holdout-dedicated-paste-negative-0847` | paste | list | `__negative__:list` | `markdown` | 0.755124 |
| `holdout-dedicated-paste-negative-0850` | paste | list | `__negative__:list` | `markdown` | 0.739260 |
| `holdout-dedicated-paste-negative-0853` | paste | list | `__negative__:list` | `markdown` | 0.753524 |
| `holdout-dedicated-paste-negative-0856` | paste | list | `__negative__:list` | `markdown` | 0.776653 |
| `holdout-dedicated-paste-negative-0859` | paste | list | `__negative__:list` | `markdown` | 0.672412 |
| `holdout-dedicated-paste-negative-0862` | paste | list | `__negative__:list` | `markdown` | 0.791126 |
| `holdout-dedicated-paste-negative-0865` | paste | list | `__negative__:list` | `markdown` | 0.631371 |
| `holdout-dedicated-paste-negative-0868` | paste | list | `__negative__:list` | `markdown` | 0.809543 |
| `holdout-dedicated-paste-negative-0871` | paste | list | `__negative__:list` | `markdown` | 0.655052 |
| `holdout-dedicated-paste-negative-0874` | paste | list | `__negative__:list` | `markdown` | 0.687091 |
| `holdout-dedicated-paste-negative-0877` | paste | list | `__negative__:list` | `markdown` | 0.721803 |
| `holdout-dedicated-paste-negative-0880` | paste | list | `__negative__:list` | `markdown` | 0.729846 |
| `holdout-dedicated-paste-negative-0883` | paste | list | `__negative__:list` | `markdown` | 0.696223 |
| `holdout-dedicated-paste-negative-0886` | paste | list | `__negative__:list` | `markdown` | 0.701172 |
| `holdout-dedicated-paste-negative-0889` | paste | list | `__negative__:list` | `markdown` | 0.615113 |
| `holdout-dedicated-paste-negative-0892` | paste | list | `__negative__:list` | `markdown` | 0.708581 |
| `holdout-dedicated-paste-negative-0895` | paste | list | `__negative__:list` | `markdown` | 0.606764 |
| `holdout-dedicated-paste-negative-0898` | paste | list | `__negative__:list` | `markdown` | 0.689700 |
| `holdout-paste-code-0004` | paste | code | `swift` | `__abstain__` | 0.321396 |
| `holdout-paste-code-0005` | paste | code | `go` | `__abstain__` | 0.362066 |
| `holdout-paste-code-0016` | paste | code | `swift` | `__abstain__` | 0.262028 |
| `holdout-paste-code-0017` | paste | code | `go` | `__abstain__` | 0.321775 |
| `holdout-paste-code-0028` | paste | code | `swift` | `__abstain__` | 0.264484 |
| `holdout-paste-code-0029` | paste | code | `go` | `__abstain__` | 0.342782 |
| `holdout-paste-code-0040` | paste | code | `swift` | `__abstain__` | 0.225432 |
| `holdout-paste-code-0041` | paste | code | `go` | `__abstain__` | 0.300366 |
| `holdout-paste-code-0052` | paste | code | `swift` | `__abstain__` | 0.243764 |
| `holdout-paste-code-0053` | paste | code | `go` | `__abstain__` | 0.365348 |
| `holdout-paste-code-0064` | paste | code | `swift` | `__abstain__` | 0.299615 |
| `holdout-paste-code-0065` | paste | code | `go` | `__abstain__` | 0.335337 |
| `holdout-paste-code-0076` | paste | code | `swift` | `__abstain__` | 0.354776 |
| `holdout-paste-code-0077` | paste | code | `go` | `__abstain__` | 0.322787 |
| `holdout-paste-code-0088` | paste | code | `swift` | `__abstain__` | 0.250153 |
| `holdout-paste-code-0089` | paste | code | `go` | `__abstain__` | 0.353783 |
| `holdout-paste-code-0100` | paste | code | `swift` | `__abstain__` | 0.136581 |
| `holdout-paste-code-0101` | paste | code | `go` | `__abstain__` | 0.312653 |
| `holdout-paste-code-0112` | paste | code | `swift` | `__abstain__` | 0.254523 |
| `holdout-paste-code-0113` | paste | code | `go` | `__abstain__` | 0.360352 |

## Artifact metadata

- Registry crate checksum SHA-256: `5f89b0929539eaee70109704ae4e345df438be6ab02e4dc8ac060e05098ad1b7`
- VCS revision: `13b5cbf7b934fdbd4be0bb7437faeb03124700de`
- Model SHA-256: `8493d2d3757572c8661141e414b1c0755aa08d4c4e5382dfbbc6b73b02d89083`
- Model size: 47840 bytes
- Verification: recorded registry artifact metadata; not re-verified at runtime

All raw ranked values are available in `cases.jsonl`. This report is evidence collection, not shipping approval.
