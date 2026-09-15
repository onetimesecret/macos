# Language evaluation report

- Split: `tune`
- Platform: `macos/aarch64`
- Profile: `release`
- Executable size: 759360 bytes
- Whole-process max RSS proxy: 7143424 bytes (/usr/bin/time)
- Cold first eligible inference: 1549833 ns
- Warm p50/p95/p99/max: 781292 ns/823416 ns/826458 ns/840875 ns

## Automatic-paste gate

- Conclusion: **insufficient_evidence**
- the gate can be concluded only from the holdout split

## Aggregate metrics

| Metric | Raw | Rate |
|---|---:|---:|
| Total cases | 734 | n/a |
| Eligible cases | 733 | n/a |
| Useful-code cases | 125 | n/a |
| Eligible useful-code cases | 125 | n/a |
| Accepted cases | 246 | n/a |
| Accepted precision (accepted useful code / all accepted) | 113/246 | 45.93% (95% CI 39.82–52.18%) |
| Exact-label precision where defined | 107/113 | 94.69% (95% CI 88.90–97.54%) |
| Useful-code coverage | 113/125 | 90.40% (95% CI 83.97–94.42%) |
| Exact useful-code coverage | 107/125 | 85.60% (95% CI 78.38–90.69%) |
| Abstention | 488/734 | 66.49% (95% CI 62.99–69.81%) |
| Negative false conversions | 133/609 | 21.84% (95% CI 18.74–25.29%) |
| Automatic paste conversions | 111 | n/a |
| Automatic paste precision | 110/111 | 99.10% (95% CI 95.07–99.84%) |
| Automatic paste useful-code coverage | 110/122 | 90.16% (95% CI 83.59–94.28%) |
| Dedicated prose/list/URL paste-negative conversions | 0/603 | 0.00% (95% CI 0.00–0.63%) |

## Metrics by product surface

| Surface | Cases | Eligible | Useful | Eligible useful | Accepted precision | Exact-label precision | Useful coverage | Exact useful coverage | Abstention | Negative false conversions |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| fence | 3 | 3 | 2 | 2 | 66.67% (95% CI 20.77–93.85%) | 100.00% (95% CI 34.24–100.00%) | 100.00% (95% CI 34.24–100.00%) | 100.00% (95% CI 34.24–100.00%) | 0.00% (95% CI 0.00–56.15%) | 100.00% (95% CI 20.65–100.00%) |
| file | 3 | 2 | 1 | 1 | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 66.67% (95% CI 20.77–93.85%) | 0.00% (95% CI 0.00–65.76%) |
| paste | 728 | 728 | 122 | 122 | 45.45% (95% CI 39.30–51.75%) | 94.55% (95% CI 88.61–97.48%) | 90.16% (95% CI 83.59–94.28%) | 85.25% (95% CI 77.88–90.46%) | 66.76% (95% CI 63.26–70.08%) | 21.78% (95% CI 18.68–25.24%) |

## Metrics by content kind

| Kind | Cases | Eligible | Useful | Eligible useful | Accepted precision | Exact-label precision | Useful coverage | Exact useful coverage | Abstention | Negative false conversions |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| binary | 1 | 0 | 0 | 0 | n/a | n/a | n/a | n/a | 100.00% (95% CI 20.65–100.00%) | 0.00% (95% CI 0.00–79.35%) |
| code | 124 | 124 | 124 | 124 | 100.00% (95% CI 96.68–100.00%) | 94.64% (95% CI 88.80–97.52%) | 90.32% (95% CI 83.84–94.38%) | 85.48% (95% CI 78.22–90.62%) | 9.68% (95% CI 5.62–16.16%) | n/a |
| config-shaped | 1 | 1 | 0 | 0 | n/a | n/a | n/a | n/a | 100.00% (95% CI 20.65–100.00%) | 0.00% (95% CI 0.00–79.35%) |
| credential-shaped | 1 | 1 | 0 | 0 | 0.00% (95% CI 0.00–79.35%) | n/a | n/a | n/a | 0.00% (95% CI 0.00–79.35%) | 100.00% (95% CI 20.65–100.00%) |
| list | 201 | 201 | 0 | 0 | 0.00% (95% CI 0.00–3.50%) | n/a | n/a | n/a | 47.26% (95% CI 40.48–54.15%) | 52.74% (95% CI 45.85–59.52%) |
| log | 1 | 1 | 0 | 0 | n/a | n/a | n/a | n/a | 100.00% (95% CI 20.65–100.00%) | 0.00% (95% CI 0.00–79.35%) |
| malformed-code | 1 | 1 | 1 | 1 | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 0.00% (95% CI 0.00–79.35%) | n/a |
| markdown | 1 | 1 | 0 | 0 | 0.00% (95% CI 0.00–79.35%) | n/a | n/a | n/a | 0.00% (95% CI 0.00–79.35%) | 100.00% (95% CI 20.65–100.00%) |
| mixed | 1 | 1 | 0 | 0 | n/a | n/a | n/a | n/a | 100.00% (95% CI 20.65–100.00%) | 0.00% (95% CI 0.00–79.35%) |
| prose | 201 | 201 | 0 | 0 | 0.00% (95% CI 0.00–13.32%) | n/a | n/a | n/a | 87.56% (95% CI 82.28–91.43%) | 12.44% (95% CI 8.57–17.72%) |
| url | 201 | 201 | 0 | 0 | n/a | n/a | n/a | n/a | 100.00% (95% CI 98.12–100.00%) | 0.00% (95% CI 0.00–1.88%) |

## Metrics by input length

| Input bytes | Cases | Eligible | Useful | Eligible useful | Accepted precision | Exact-label precision | Useful coverage | Exact useful coverage | Abstention | Negative false conversions |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 020-079 | 445 | 444 | 41 | 41 | 27.89% (95% CI 21.28–35.63%) | 100.00% (95% CI 91.43–100.00%) | 100.00% (95% CI 91.43–100.00%) | 100.00% (95% CI 91.43–100.00%) | 66.97% (95% CI 62.47–71.17%) | 26.24% (95% CI 22.19–30.74%) |
| 080-255 | 289 | 289 | 84 | 84 | 72.73% (95% CI 63.23–80.53%) | 91.67% (95% CI 82.99–96.12%) | 85.71% (95% CI 76.67–91.63%) | 78.57% (95% CI 68.65–85.99%) | 65.74% (95% CI 60.10–70.98%) | 13.17% (95% CI 9.21–18.48%) |

## Confusion matrix

| Expected | Outcome | Count |
|---|---|---:|
| `__negative__:binary` | `__abstain__` | 1 |
| `__negative__:config-shaped` | `__abstain__` | 1 |
| `__negative__:credential-shaped` | `yaml` | 1 |
| `__negative__:list` | `__abstain__` | 95 |
| `__negative__:list` | `markdown` | 106 |
| `__negative__:log` | `__abstain__` | 1 |
| `__negative__:markdown` | `markdown` | 1 |
| `__negative__:mixed` | `__abstain__` | 1 |
| `__negative__:prose` | `__abstain__` | 176 |
| `__negative__:prose` | `markdown` | 25 |
| `__negative__:url` | `__abstain__` | 201 |
| `go` | `go` | 10 |
| `javascript` | `javascript` | 11 |
| `json` | `json` | 11 |
| `python` | `python` | 11 |
| `ruby` | `ruby` | 10 |
| `rust` | `__abstain__` | 5 |
| `rust` | `javascript` | 6 |
| `shell` | `shell` | 10 |
| `sql` | `sql` | 11 |
| `swift` | `__abstain__` | 6 |
| `swift` | `swift` | 4 |
| `toml` | `toml` | 10 |
| `typescript` | `__abstain__` | 1 |
| `typescript` | `typescript` | 9 |
| `yaml` | `yaml` | 10 |

## Confusion pairs

| Pair | Count |
|---|---:|
| `__negative__:credential-shaped -> yaml` | 1 |
| `__negative__:list -> markdown` | 106 |
| `__negative__:markdown -> markdown` | 1 |
| `__negative__:prose -> markdown` | 25 |
| `rust -> __abstain__` | 5 |
| `rust -> javascript` | 6 |
| `swift -> __abstain__` | 6 |
| `typescript -> __abstain__` | 1 |

## Detailed confusion cases

| Case | Surface | Kind | Expected | Outcome | Top score |
|---|---|---|---|---|---:|
| `tune-rust` | paste | code | `rust` | `__abstain__` | 0.247980 |
| `tune-list` | paste | list | `__negative__:list` | `markdown` | 0.473224 |
| `tune-credential` | paste | credential-shaped | `__negative__:credential-shaped` | `yaml` | 0.878070 |
| `tune-markdown` | fence | markdown | `__negative__:markdown` | `markdown` | 0.927418 |
| `tune-dedicated-paste-negative-0007` | paste | list | `__negative__:list` | `markdown` | 0.606697 |
| `tune-dedicated-paste-negative-0010` | paste | list | `__negative__:list` | `markdown` | 0.546140 |
| `tune-dedicated-paste-negative-0018` | paste | prose | `__negative__:prose` | `markdown` | 0.464507 |
| `tune-dedicated-paste-negative-0019` | paste | list | `__negative__:list` | `markdown` | 0.418781 |
| `tune-dedicated-paste-negative-0025` | paste | list | `__negative__:list` | `markdown` | 0.501157 |
| `tune-dedicated-paste-negative-0031` | paste | list | `__negative__:list` | `markdown` | 0.643365 |
| `tune-dedicated-paste-negative-0034` | paste | list | `__negative__:list` | `markdown` | 0.587547 |
| `tune-dedicated-paste-negative-0042` | paste | prose | `__negative__:prose` | `markdown` | 0.427930 |
| `tune-dedicated-paste-negative-0043` | paste | list | `__negative__:list` | `markdown` | 0.448175 |
| `tune-dedicated-paste-negative-0049` | paste | list | `__negative__:list` | `markdown` | 0.522898 |
| `tune-dedicated-paste-negative-0055` | paste | list | `__negative__:list` | `markdown` | 0.648127 |
| `tune-dedicated-paste-negative-0058` | paste | list | `__negative__:list` | `markdown` | 0.597813 |
| `tune-dedicated-paste-negative-0066` | paste | prose | `__negative__:prose` | `markdown` | 0.420381 |
| `tune-dedicated-paste-negative-0067` | paste | list | `__negative__:list` | `markdown` | 0.480157 |
| `tune-dedicated-paste-negative-0073` | paste | list | `__negative__:list` | `markdown` | 0.539719 |
| `tune-dedicated-paste-negative-0079` | paste | list | `__negative__:list` | `markdown` | 0.657496 |
| `tune-dedicated-paste-negative-0082` | paste | list | `__negative__:list` | `markdown` | 0.587121 |
| `tune-dedicated-paste-negative-0090` | paste | prose | `__negative__:prose` | `markdown` | 0.437915 |
| `tune-dedicated-paste-negative-0091` | paste | list | `__negative__:list` | `markdown` | 0.484321 |
| `tune-dedicated-paste-negative-0097` | paste | list | `__negative__:list` | `markdown` | 0.558109 |
| `tune-dedicated-paste-negative-0103` | paste | list | `__negative__:list` | `markdown` | 0.652113 |
| `tune-dedicated-paste-negative-0106` | paste | list | `__negative__:list` | `markdown` | 0.592511 |
| `tune-dedicated-paste-negative-0114` | paste | prose | `__negative__:prose` | `markdown` | 0.433594 |
| `tune-dedicated-paste-negative-0115` | paste | list | `__negative__:list` | `markdown` | 0.465331 |
| `tune-dedicated-paste-negative-0121` | paste | list | `__negative__:list` | `markdown` | 0.530743 |
| `tune-dedicated-paste-negative-0124` | paste | list | `__negative__:list` | `markdown` | 0.410979 |
| `tune-dedicated-paste-negative-0127` | paste | list | `__negative__:list` | `markdown` | 0.646437 |
| `tune-dedicated-paste-negative-0130` | paste | list | `__negative__:list` | `markdown` | 0.626717 |
| `tune-dedicated-paste-negative-0138` | paste | prose | `__negative__:prose` | `markdown` | 0.452498 |
| `tune-dedicated-paste-negative-0139` | paste | list | `__negative__:list` | `markdown` | 0.475340 |
| `tune-dedicated-paste-negative-0145` | paste | list | `__negative__:list` | `markdown` | 0.549433 |
| `tune-dedicated-paste-negative-0151` | paste | list | `__negative__:list` | `markdown` | 0.671109 |
| `tune-dedicated-paste-negative-0154` | paste | list | `__negative__:list` | `markdown` | 0.616324 |
| `tune-dedicated-paste-negative-0162` | paste | prose | `__negative__:prose` | `markdown` | 0.431204 |
| `tune-dedicated-paste-negative-0163` | paste | list | `__negative__:list` | `markdown` | 0.488443 |
| `tune-dedicated-paste-negative-0169` | paste | list | `__negative__:list` | `markdown` | 0.547485 |
| `tune-dedicated-paste-negative-0175` | paste | list | `__negative__:list` | `markdown` | 0.627578 |
| `tune-dedicated-paste-negative-0178` | paste | list | `__negative__:list` | `markdown` | 0.627226 |
| `tune-dedicated-paste-negative-0186` | paste | prose | `__negative__:prose` | `markdown` | 0.450460 |
| `tune-dedicated-paste-negative-0187` | paste | list | `__negative__:list` | `markdown` | 0.471021 |
| `tune-dedicated-paste-negative-0193` | paste | list | `__negative__:list` | `markdown` | 0.504096 |
| `tune-dedicated-paste-negative-0199` | paste | list | `__negative__:list` | `markdown` | 0.645861 |
| `tune-dedicated-paste-negative-0202` | paste | list | `__negative__:list` | `markdown` | 0.607405 |
| `tune-dedicated-paste-negative-0210` | paste | prose | `__negative__:prose` | `markdown` | 0.462139 |
| `tune-dedicated-paste-negative-0211` | paste | list | `__negative__:list` | `markdown` | 0.448441 |
| `tune-dedicated-paste-negative-0217` | paste | list | `__negative__:list` | `markdown` | 0.540976 |
| `tune-dedicated-paste-negative-0223` | paste | list | `__negative__:list` | `markdown` | 0.691271 |
| `tune-dedicated-paste-negative-0226` | paste | list | `__negative__:list` | `markdown` | 0.580297 |
| `tune-dedicated-paste-negative-0234` | paste | prose | `__negative__:prose` | `markdown` | 0.446219 |
| `tune-dedicated-paste-negative-0235` | paste | list | `__negative__:list` | `markdown` | 0.487141 |
| `tune-dedicated-paste-negative-0241` | paste | list | `__negative__:list` | `markdown` | 0.547297 |
| `tune-dedicated-paste-negative-0244` | paste | list | `__negative__:list` | `markdown` | 0.430333 |
| `tune-dedicated-paste-negative-0247` | paste | list | `__negative__:list` | `markdown` | 0.655118 |
| `tune-dedicated-paste-negative-0250` | paste | list | `__negative__:list` | `markdown` | 0.590643 |
| `tune-dedicated-paste-negative-0258` | paste | prose | `__negative__:prose` | `markdown` | 0.457338 |
| `tune-dedicated-paste-negative-0259` | paste | list | `__negative__:list` | `markdown` | 0.471914 |
| `tune-dedicated-paste-negative-0271` | paste | list | `__negative__:list` | `markdown` | 0.659594 |
| `tune-dedicated-paste-negative-0274` | paste | list | `__negative__:list` | `markdown` | 0.587983 |
| `tune-dedicated-paste-negative-0282` | paste | prose | `__negative__:prose` | `markdown` | 0.434311 |
| `tune-dedicated-paste-negative-0283` | paste | list | `__negative__:list` | `markdown` | 0.516963 |
| `tune-dedicated-paste-negative-0289` | paste | list | `__negative__:list` | `markdown` | 0.564728 |
| `tune-dedicated-paste-negative-0292` | paste | list | `__negative__:list` | `markdown` | 0.415279 |
| `tune-dedicated-paste-negative-0295` | paste | list | `__negative__:list` | `markdown` | 0.644949 |
| `tune-dedicated-paste-negative-0298` | paste | list | `__negative__:list` | `markdown` | 0.627129 |
| `tune-dedicated-paste-negative-0306` | paste | prose | `__negative__:prose` | `markdown` | 0.463908 |
| `tune-dedicated-paste-negative-0307` | paste | list | `__negative__:list` | `markdown` | 0.439616 |
| `tune-dedicated-paste-negative-0313` | paste | list | `__negative__:list` | `markdown` | 0.532531 |
| `tune-dedicated-paste-negative-0316` | paste | list | `__negative__:list` | `markdown` | 0.438583 |
| `tune-dedicated-paste-negative-0319` | paste | list | `__negative__:list` | `markdown` | 0.668659 |
| `tune-dedicated-paste-negative-0322` | paste | list | `__negative__:list` | `markdown` | 0.565128 |
| `tune-dedicated-paste-negative-0330` | paste | prose | `__negative__:prose` | `markdown` | 0.450526 |
| `tune-dedicated-paste-negative-0331` | paste | list | `__negative__:list` | `markdown` | 0.485729 |
| `tune-dedicated-paste-negative-0337` | paste | list | `__negative__:list` | `markdown` | 0.595496 |
| `tune-dedicated-paste-negative-0340` | paste | list | `__negative__:list` | `markdown` | 0.410067 |
| `tune-dedicated-paste-negative-0343` | paste | list | `__negative__:list` | `markdown` | 0.639560 |
| `tune-dedicated-paste-negative-0346` | paste | list | `__negative__:list` | `markdown` | 0.611770 |
| `tune-dedicated-paste-negative-0354` | paste | prose | `__negative__:prose` | `markdown` | 0.467216 |
| `tune-dedicated-paste-negative-0355` | paste | list | `__negative__:list` | `markdown` | 0.486570 |
| `tune-dedicated-paste-negative-0361` | paste | list | `__negative__:list` | `markdown` | 0.537225 |
| `tune-dedicated-paste-negative-0367` | paste | list | `__negative__:list` | `markdown` | 0.650954 |
| `tune-dedicated-paste-negative-0370` | paste | list | `__negative__:list` | `markdown` | 0.657743 |
| `tune-dedicated-paste-negative-0378` | paste | prose | `__negative__:prose` | `markdown` | 0.407646 |
| `tune-dedicated-paste-negative-0379` | paste | list | `__negative__:list` | `markdown` | 0.474724 |
| `tune-dedicated-paste-negative-0385` | paste | list | `__negative__:list` | `markdown` | 0.523393 |
| `tune-dedicated-paste-negative-0388` | paste | list | `__negative__:list` | `markdown` | 0.410507 |
| `tune-dedicated-paste-negative-0391` | paste | list | `__negative__:list` | `markdown` | 0.639059 |
| `tune-dedicated-paste-negative-0394` | paste | list | `__negative__:list` | `markdown` | 0.636516 |
| `tune-dedicated-paste-negative-0402` | paste | prose | `__negative__:prose` | `markdown` | 0.455894 |
| `tune-dedicated-paste-negative-0403` | paste | list | `__negative__:list` | `markdown` | 0.459847 |
| `tune-dedicated-paste-negative-0415` | paste | list | `__negative__:list` | `markdown` | 0.683365 |
| `tune-dedicated-paste-negative-0418` | paste | list | `__negative__:list` | `markdown` | 0.575281 |
| `tune-dedicated-paste-negative-0426` | paste | prose | `__negative__:prose` | `markdown` | 0.441450 |
| `tune-dedicated-paste-negative-0433` | paste | list | `__negative__:list` | `markdown` | 0.598624 |
| `tune-dedicated-paste-negative-0436` | paste | list | `__negative__:list` | `markdown` | 0.442151 |
| `tune-dedicated-paste-negative-0439` | paste | list | `__negative__:list` | `markdown` | 0.652648 |
| `tune-dedicated-paste-negative-0442` | paste | list | `__negative__:list` | `markdown` | 0.617774 |
| `tune-dedicated-paste-negative-0450` | paste | prose | `__negative__:prose` | `markdown` | 0.459673 |
| `tune-dedicated-paste-negative-0451` | paste | list | `__negative__:list` | `markdown` | 0.466745 |
| `tune-dedicated-paste-negative-0457` | paste | list | `__negative__:list` | `markdown` | 0.548667 |
| `tune-dedicated-paste-negative-0460` | paste | list | `__negative__:list` | `markdown` | 0.423030 |
| `tune-dedicated-paste-negative-0463` | paste | list | `__negative__:list` | `markdown` | 0.679071 |
| `tune-dedicated-paste-negative-0466` | paste | list | `__negative__:list` | `markdown` | 0.618950 |
| `tune-dedicated-paste-negative-0474` | paste | prose | `__negative__:prose` | `markdown` | 0.441432 |
| `tune-dedicated-paste-negative-0475` | paste | list | `__negative__:list` | `markdown` | 0.504995 |
| `tune-dedicated-paste-negative-0481` | paste | list | `__negative__:list` | `markdown` | 0.550971 |
| `tune-dedicated-paste-negative-0484` | paste | list | `__negative__:list` | `markdown` | 0.428708 |
| `tune-dedicated-paste-negative-0487` | paste | list | `__negative__:list` | `markdown` | 0.643338 |
| `tune-dedicated-paste-negative-0490` | paste | list | `__negative__:list` | `markdown` | 0.606676 |
| `tune-dedicated-paste-negative-0498` | paste | prose | `__negative__:prose` | `markdown` | 0.452967 |
| `tune-dedicated-paste-negative-0499` | paste | list | `__negative__:list` | `markdown` | 0.486196 |
| `tune-dedicated-paste-negative-0505` | paste | list | `__negative__:list` | `markdown` | 0.590507 |
| `tune-dedicated-paste-negative-0511` | paste | list | `__negative__:list` | `markdown` | 0.658236 |
| `tune-dedicated-paste-negative-0514` | paste | list | `__negative__:list` | `markdown` | 0.620314 |
| `tune-dedicated-paste-negative-0522` | paste | prose | `__negative__:prose` | `markdown` | 0.449361 |
| `tune-dedicated-paste-negative-0523` | paste | list | `__negative__:list` | `markdown` | 0.452924 |
| `tune-dedicated-paste-negative-0532` | paste | list | `__negative__:list` | `markdown` | 0.434683 |
| `tune-dedicated-paste-negative-0535` | paste | list | `__negative__:list` | `markdown` | 0.614419 |
| `tune-dedicated-paste-negative-0538` | paste | list | `__negative__:list` | `markdown` | 0.597088 |
| `tune-dedicated-paste-negative-0546` | paste | prose | `__negative__:prose` | `markdown` | 0.460570 |
| `tune-dedicated-paste-negative-0547` | paste | list | `__negative__:list` | `markdown` | 0.464577 |
| `tune-dedicated-paste-negative-0553` | paste | list | `__negative__:list` | `markdown` | 0.531982 |
| `tune-dedicated-paste-negative-0559` | paste | list | `__negative__:list` | `markdown` | 0.632005 |
| `tune-dedicated-paste-negative-0562` | paste | list | `__negative__:list` | `markdown` | 0.621999 |
| `tune-dedicated-paste-negative-0570` | paste | prose | `__negative__:prose` | `markdown` | 0.420951 |
| `tune-dedicated-paste-negative-0571` | paste | list | `__negative__:list` | `markdown` | 0.462642 |
| `tune-dedicated-paste-negative-0577` | paste | list | `__negative__:list` | `markdown` | 0.578893 |
| `tune-dedicated-paste-negative-0583` | paste | list | `__negative__:list` | `markdown` | 0.628181 |
| `tune-dedicated-paste-negative-0586` | paste | list | `__negative__:list` | `markdown` | 0.621679 |
| `tune-dedicated-paste-negative-0594` | paste | prose | `__negative__:prose` | `markdown` | 0.448293 |
| `tune-dedicated-paste-negative-0595` | paste | list | `__negative__:list` | `markdown` | 0.499278 |
| `tune-paste-code-0000` | paste | code | `rust` | `javascript` | 0.526202 |
| `tune-paste-code-0004` | paste | code | `swift` | `__abstain__` | 0.386257 |
| `tune-paste-code-0012` | paste | code | `rust` | `javascript` | 0.505925 |
| `tune-paste-code-0016` | paste | code | `swift` | `__abstain__` | 0.363458 |
| `tune-paste-code-0024` | paste | code | `rust` | `javascript` | 0.499358 |
| `tune-paste-code-0028` | paste | code | `swift` | `__abstain__` | 0.391005 |
| `tune-paste-code-0036` | paste | code | `rust` | `__abstain__` | 0.441288 |
| `tune-paste-code-0048` | paste | code | `rust` | `__abstain__` | 0.436539 |
| `tune-paste-code-0060` | paste | code | `rust` | `javascript` | 0.441300 |
| `tune-paste-code-0064` | paste | code | `swift` | `__abstain__` | 0.351429 |
| `tune-paste-code-0072` | paste | code | `rust` | `__abstain__` | 0.420194 |
| `tune-paste-code-0075` | paste | code | `typescript` | `__abstain__` | 0.430341 |
| `tune-paste-code-0076` | paste | code | `swift` | `__abstain__` | 0.305206 |
| `tune-paste-code-0084` | paste | code | `rust` | `javascript` | 0.439708 |
| `tune-paste-code-0096` | paste | code | `rust` | `__abstain__` | 0.438241 |
| `tune-paste-code-0100` | paste | code | `swift` | `__abstain__` | 0.385421 |
| `tune-paste-code-0108` | paste | code | `rust` | `javascript` | 0.463666 |

## Artifact metadata

- Registry crate checksum SHA-256: `5f89b0929539eaee70109704ae4e345df438be6ab02e4dc8ac060e05098ad1b7`
- VCS revision: `13b5cbf7b934fdbd4be0bb7437faeb03124700de`
- Model SHA-256: `8493d2d3757572c8661141e414b1c0755aa08d4c4e5382dfbbc6b73b02d89083`
- Model size: 47840 bytes
- Verification: recorded registry artifact metadata; not re-verified at runtime

All raw ranked values are available in `cases.jsonl`. This report is evidence collection, not shipping approval.
