# Language evaluation report

- Split: `holdout`
- Platform: `macos/aarch64`
- Profile: `release`
- Executable size: 742608 bytes
- Whole-process max RSS proxy: 8863744 bytes (/usr/bin/time)
- Cold first eligible inference: 1615583 ns
- Warm p50/p95/p99/max: 852208 ns/896833 ns/936000 ns/937167 ns

## Automatic-paste gate

- Conclusion: **fail**
- automatic-paste precision is 115/128; at least 99% required
- 12 dedicated negative conversions observed; zero required

## Aggregate metrics

| Metric | Raw | Rate |
|---|---:|---:|
| Total cases | 1334 | n/a |
| Eligible cases | 1333 | n/a |
| Useful-code cases | 125 | n/a |
| Eligible useful-code cases | 125 | n/a |
| Accepted cases | 408 | n/a |
| Accepted precision (accepted useful code / all accepted) | 118/408 | 28.92% (95% CI 24.73–33.50%) |
| Exact-label precision where defined | 110/118 | 93.22% (95% CI 87.19–96.52%) |
| Useful-code coverage | 118/125 | 94.40% (95% CI 88.89–97.26%) |
| Exact useful-code coverage | 110/125 | 88.00% (95% CI 81.14–92.59%) |
| Abstention | 926/1334 | 69.42% (95% CI 66.89–71.83%) |
| Negative false conversions | 290/1209 | 23.99% (95% CI 21.66–26.47%) |
| Automatic paste conversions | 128 | n/a |
| Automatic paste precision | 115/128 | 89.84% (95% CI 83.40–93.97%) |
| Automatic paste useful-code coverage | 115/122 | 94.26% (95% CI 88.63–97.19%) |
| Dedicated prose/list/URL paste-negative conversions | 12/1203 | 1.00% (95% CI 0.57–1.74%) |

## Metrics by product surface

| Surface | Cases | Eligible | Useful | Eligible useful | Accepted precision | Exact-label precision | Useful coverage | Exact useful coverage | Abstention | Negative false conversions |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| fence | 3 | 3 | 2 | 2 | 66.67% (95% CI 20.77–93.85%) | 100.00% (95% CI 34.24–100.00%) | 100.00% (95% CI 34.24–100.00%) | 100.00% (95% CI 34.24–100.00%) | 0.00% (95% CI 0.00–56.15%) | 100.00% (95% CI 20.65–100.00%) |
| file | 3 | 2 | 1 | 1 | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 66.67% (95% CI 20.77–93.85%) | 0.00% (95% CI 0.00–65.76%) |
| paste | 1328 | 1328 | 122 | 122 | 28.47% (95% CI 24.28–33.05%) | 93.04% (95% CI 86.87–96.43%) | 94.26% (95% CI 88.63–97.19%) | 87.70% (95% CI 80.70–92.41%) | 69.58% (95% CI 67.05–71.99%) | 23.96% (95% CI 21.64–26.45%) |

## Metrics by content kind

| Kind | Cases | Eligible | Useful | Eligible useful | Accepted precision | Exact-label precision | Useful coverage | Exact useful coverage | Abstention | Negative false conversions |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| binary | 1 | 0 | 0 | 0 | n/a | n/a | n/a | n/a | 100.00% (95% CI 20.65–100.00%) | 0.00% (95% CI 0.00–79.35%) |
| code | 124 | 124 | 124 | 124 | 100.00% (95% CI 96.82–100.00%) | 93.16% (95% CI 87.09–96.49%) | 94.35% (95% CI 88.81–97.24%) | 87.90% (95% CI 81.00–92.53%) | 5.65% (95% CI 2.76–11.19%) | n/a |
| config-shaped | 1 | 1 | 0 | 0 | n/a | n/a | n/a | n/a | 100.00% (95% CI 20.65–100.00%) | 0.00% (95% CI 0.00–79.35%) |
| credential-shaped | 1 | 1 | 0 | 0 | 0.00% (95% CI 0.00–79.35%) | n/a | n/a | n/a | 0.00% (95% CI 0.00–79.35%) | 100.00% (95% CI 20.65–100.00%) |
| list | 401 | 401 | 0 | 0 | 0.00% (95% CI 0.00–1.59%) | n/a | n/a | n/a | 40.65% (95% CI 35.95–45.52%) | 59.35% (95% CI 54.48–64.05%) |
| log | 1 | 1 | 0 | 0 | n/a | n/a | n/a | n/a | 100.00% (95% CI 20.65–100.00%) | 0.00% (95% CI 0.00–79.35%) |
| malformed-code | 1 | 1 | 1 | 1 | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 100.00% (95% CI 20.65–100.00%) | 0.00% (95% CI 0.00–79.35%) | n/a |
| markdown | 1 | 1 | 0 | 0 | 0.00% (95% CI 0.00–79.35%) | n/a | n/a | n/a | 0.00% (95% CI 0.00–79.35%) | 100.00% (95% CI 20.65–100.00%) |
| mixed | 1 | 1 | 0 | 0 | n/a | n/a | n/a | n/a | 100.00% (95% CI 20.65–100.00%) | 0.00% (95% CI 0.00–79.35%) |
| prose | 401 | 401 | 0 | 0 | 0.00% (95% CI 0.00–7.13%) | n/a | n/a | n/a | 87.53% (95% CI 83.94–90.41%) | 12.47% (95% CI 9.59–16.06%) |
| url | 401 | 401 | 0 | 0 | n/a | n/a | n/a | n/a | 100.00% (95% CI 99.05–100.00%) | 0.00% (95% CI 0.00–0.95%) |

## Metrics by input length

| Input bytes | Cases | Eligible | Useful | Eligible useful | Accepted precision | Exact-label precision | Useful coverage | Exact useful coverage | Abstention | Negative false conversions |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 020-079 | 847 | 846 | 41 | 41 | 14.59% (95% CI 10.94–19.20%) | 100.00% (95% CI 91.43–100.00%) | 100.00% (95% CI 91.43–100.00%) | 100.00% (95% CI 91.43–100.00%) | 66.82% (95% CI 63.58–69.91%) | 29.78% (95% CI 26.72–33.02%) |
| 080-255 | 487 | 487 | 84 | 84 | 60.63% (95% CI 51.94–68.70%) | 89.61% (95% CI 80.82–94.64%) | 91.67% (95% CI 83.78–95.90%) | 82.14% (95% CI 72.61–88.87%) | 73.92% (95% CI 69.85–77.62%) | 12.41% (95% CI 9.54–15.98%) |

## Confusion matrix

| Expected | Outcome | Count |
|---|---|---:|
| `__negative__:binary` | `__abstain__` | 1 |
| `__negative__:config-shaped` | `__abstain__` | 1 |
| `__negative__:credential-shaped` | `ini` | 1 |
| `__negative__:list` | `__abstain__` | 163 |
| `__negative__:list` | `haskell` | 12 |
| `__negative__:list` | `markdown` | 226 |
| `__negative__:log` | `__abstain__` | 1 |
| `__negative__:markdown` | `markdown` | 1 |
| `__negative__:mixed` | `__abstain__` | 1 |
| `__negative__:prose` | `__abstain__` | 351 |
| `__negative__:prose` | `markdown` | 50 |
| `__negative__:url` | `__abstain__` | 401 |
| `go` | `go` | 11 |
| `html` | `html` | 1 |
| `javascript` | `javascript` | 10 |
| `json` | `json` | 10 |
| `python` | `python` | 11 |
| `ruby` | `ruby` | 10 |
| `rust` | `__abstain__` | 2 |
| `rust` | `javascript` | 8 |
| `shell` | `shell` | 11 |
| `sql` | `sql` | 10 |
| `swift` | `__abstain__` | 4 |
| `swift` | `swift` | 7 |
| `toml` | `toml` | 10 |
| `typescript` | `__abstain__` | 1 |
| `typescript` | `typescript` | 9 |
| `yaml` | `yaml` | 10 |

## Confusion pairs

| Pair | Count |
|---|---:|
| `__negative__:credential-shaped -> ini` | 1 |
| `__negative__:list -> haskell` | 12 |
| `__negative__:list -> markdown` | 226 |
| `__negative__:markdown -> markdown` | 1 |
| `__negative__:prose -> markdown` | 50 |
| `rust -> __abstain__` | 2 |
| `rust -> javascript` | 8 |
| `swift -> __abstain__` | 4 |
| `typescript -> __abstain__` | 1 |

## Detailed confusion cases

| Case | Surface | Kind | Expected | Outcome | Top score |
|---|---|---|---|---|---:|
| `holdout-list` | paste | list | `__negative__:list` | `markdown` | 0.401705 |
| `holdout-credential` | paste | credential-shaped | `__negative__:credential-shaped` | `ini` | 0.745027 |
| `holdout-markdown` | fence | markdown | `__negative__:markdown` | `markdown` | 0.839685 |
| `holdout-dedicated-paste-negative-0001` | paste | list | `__negative__:list` | `markdown` | 0.520146 |
| `holdout-dedicated-paste-negative-0004` | paste | list | `__negative__:list` | `markdown` | 0.413565 |
| `holdout-dedicated-paste-negative-0007` | paste | list | `__negative__:list` | `markdown` | 0.656245 |
| `holdout-dedicated-paste-negative-0010` | paste | list | `__negative__:list` | `markdown` | 0.613339 |
| `holdout-dedicated-paste-negative-0018` | paste | prose | `__negative__:prose` | `markdown` | 0.461208 |
| `holdout-dedicated-paste-negative-0019` | paste | list | `__negative__:list` | `markdown` | 0.446102 |
| `holdout-dedicated-paste-negative-0025` | paste | list | `__negative__:list` | `markdown` | 0.565113 |
| `holdout-dedicated-paste-negative-0028` | paste | list | `__negative__:list` | `markdown` | 0.418167 |
| `holdout-dedicated-paste-negative-0031` | paste | list | `__negative__:list` | `markdown` | 0.660222 |
| `holdout-dedicated-paste-negative-0034` | paste | list | `__negative__:list` | `markdown` | 0.603377 |
| `holdout-dedicated-paste-negative-0037` | paste | list | `__negative__:list` | `haskell` | 0.431978 |
| `holdout-dedicated-paste-negative-0042` | paste | prose | `__negative__:prose` | `markdown` | 0.448997 |
| `holdout-dedicated-paste-negative-0043` | paste | list | `__negative__:list` | `markdown` | 0.481658 |
| `holdout-dedicated-paste-negative-0049` | paste | list | `__negative__:list` | `markdown` | 0.570403 |
| `holdout-dedicated-paste-negative-0055` | paste | list | `__negative__:list` | `markdown` | 0.669888 |
| `holdout-dedicated-paste-negative-0058` | paste | list | `__negative__:list` | `markdown` | 0.555646 |
| `holdout-dedicated-paste-negative-0061` | paste | list | `__negative__:list` | `haskell` | 0.410382 |
| `holdout-dedicated-paste-negative-0066` | paste | prose | `__negative__:prose` | `markdown` | 0.423052 |
| `holdout-dedicated-paste-negative-0067` | paste | list | `__negative__:list` | `markdown` | 0.483119 |
| `holdout-dedicated-paste-negative-0073` | paste | list | `__negative__:list` | `markdown` | 0.550111 |
| `holdout-dedicated-paste-negative-0076` | paste | list | `__negative__:list` | `markdown` | 0.420494 |
| `holdout-dedicated-paste-negative-0079` | paste | list | `__negative__:list` | `markdown` | 0.673086 |
| `holdout-dedicated-paste-negative-0082` | paste | list | `__negative__:list` | `markdown` | 0.560732 |
| `holdout-dedicated-paste-negative-0085` | paste | list | `__negative__:list` | `haskell` | 0.425520 |
| `holdout-dedicated-paste-negative-0090` | paste | prose | `__negative__:prose` | `markdown` | 0.477222 |
| `holdout-dedicated-paste-negative-0091` | paste | list | `__negative__:list` | `markdown` | 0.433318 |
| `holdout-dedicated-paste-negative-0097` | paste | list | `__negative__:list` | `markdown` | 0.531222 |
| `holdout-dedicated-paste-negative-0100` | paste | list | `__negative__:list` | `markdown` | 0.465969 |
| `holdout-dedicated-paste-negative-0103` | paste | list | `__negative__:list` | `markdown` | 0.648348 |
| `holdout-dedicated-paste-negative-0106` | paste | list | `__negative__:list` | `markdown` | 0.577845 |
| `holdout-dedicated-paste-negative-0114` | paste | prose | `__negative__:prose` | `markdown` | 0.431421 |
| `holdout-dedicated-paste-negative-0115` | paste | list | `__negative__:list` | `markdown` | 0.465656 |
| `holdout-dedicated-paste-negative-0121` | paste | list | `__negative__:list` | `markdown` | 0.502821 |
| `holdout-dedicated-paste-negative-0127` | paste | list | `__negative__:list` | `markdown` | 0.627536 |
| `holdout-dedicated-paste-negative-0130` | paste | list | `__negative__:list` | `markdown` | 0.573441 |
| `holdout-dedicated-paste-negative-0138` | paste | prose | `__negative__:prose` | `markdown` | 0.445861 |
| `holdout-dedicated-paste-negative-0139` | paste | list | `__negative__:list` | `markdown` | 0.489185 |
| `holdout-dedicated-paste-negative-0145` | paste | list | `__negative__:list` | `markdown` | 0.618358 |
| `holdout-dedicated-paste-negative-0151` | paste | list | `__negative__:list` | `markdown` | 0.654426 |
| `holdout-dedicated-paste-negative-0154` | paste | list | `__negative__:list` | `markdown` | 0.613468 |
| `holdout-dedicated-paste-negative-0162` | paste | prose | `__negative__:prose` | `markdown` | 0.448248 |
| `holdout-dedicated-paste-negative-0163` | paste | list | `__negative__:list` | `markdown` | 0.487526 |
| `holdout-dedicated-paste-negative-0169` | paste | list | `__negative__:list` | `markdown` | 0.612148 |
| `holdout-dedicated-paste-negative-0175` | paste | list | `__negative__:list` | `markdown` | 0.650191 |
| `holdout-dedicated-paste-negative-0178` | paste | list | `__negative__:list` | `markdown` | 0.642333 |
| `holdout-dedicated-paste-negative-0186` | paste | prose | `__negative__:prose` | `markdown` | 0.444923 |
| `holdout-dedicated-paste-negative-0187` | paste | list | `__negative__:list` | `markdown` | 0.446042 |
| `holdout-dedicated-paste-negative-0193` | paste | list | `__negative__:list` | `markdown` | 0.575138 |
| `holdout-dedicated-paste-negative-0196` | paste | list | `__negative__:list` | `markdown` | 0.409440 |
| `holdout-dedicated-paste-negative-0199` | paste | list | `__negative__:list` | `markdown` | 0.630907 |
| `holdout-dedicated-paste-negative-0202` | paste | list | `__negative__:list` | `markdown` | 0.645959 |
| `holdout-dedicated-paste-negative-0210` | paste | prose | `__negative__:prose` | `markdown` | 0.459625 |
| `holdout-dedicated-paste-negative-0211` | paste | list | `__negative__:list` | `markdown` | 0.454654 |
| `holdout-dedicated-paste-negative-0217` | paste | list | `__negative__:list` | `markdown` | 0.566911 |
| `holdout-dedicated-paste-negative-0220` | paste | list | `__negative__:list` | `markdown` | 0.487130 |
| `holdout-dedicated-paste-negative-0223` | paste | list | `__negative__:list` | `markdown` | 0.619508 |
| `holdout-dedicated-paste-negative-0226` | paste | list | `__negative__:list` | `markdown` | 0.622962 |
| `holdout-dedicated-paste-negative-0234` | paste | prose | `__negative__:prose` | `markdown` | 0.485477 |
| `holdout-dedicated-paste-negative-0235` | paste | list | `__negative__:list` | `markdown` | 0.472201 |
| `holdout-dedicated-paste-negative-0241` | paste | list | `__negative__:list` | `markdown` | 0.520704 |
| `holdout-dedicated-paste-negative-0247` | paste | list | `__negative__:list` | `markdown` | 0.646821 |
| `holdout-dedicated-paste-negative-0250` | paste | list | `__negative__:list` | `markdown` | 0.577790 |
| `holdout-dedicated-paste-negative-0258` | paste | prose | `__negative__:prose` | `markdown` | 0.431415 |
| `holdout-dedicated-paste-negative-0259` | paste | list | `__negative__:list` | `markdown` | 0.468726 |
| `holdout-dedicated-paste-negative-0265` | paste | list | `__negative__:list` | `markdown` | 0.608476 |
| `holdout-dedicated-paste-negative-0271` | paste | list | `__negative__:list` | `markdown` | 0.660244 |
| `holdout-dedicated-paste-negative-0274` | paste | list | `__negative__:list` | `markdown` | 0.588953 |
| `holdout-dedicated-paste-negative-0282` | paste | prose | `__negative__:prose` | `markdown` | 0.446996 |
| `holdout-dedicated-paste-negative-0283` | paste | list | `__negative__:list` | `markdown` | 0.486584 |
| `holdout-dedicated-paste-negative-0289` | paste | list | `__negative__:list` | `markdown` | 0.499133 |
| `holdout-dedicated-paste-negative-0292` | paste | list | `__negative__:list` | `markdown` | 0.433411 |
| `holdout-dedicated-paste-negative-0295` | paste | list | `__negative__:list` | `markdown` | 0.632041 |
| `holdout-dedicated-paste-negative-0298` | paste | list | `__negative__:list` | `markdown` | 0.628621 |
| `holdout-dedicated-paste-negative-0306` | paste | prose | `__negative__:prose` | `markdown` | 0.480211 |
| `holdout-dedicated-paste-negative-0307` | paste | list | `__negative__:list` | `markdown` | 0.491825 |
| `holdout-dedicated-paste-negative-0313` | paste | list | `__negative__:list` | `markdown` | 0.562016 |
| `holdout-dedicated-paste-negative-0316` | paste | list | `__negative__:list` | `markdown` | 0.438297 |
| `holdout-dedicated-paste-negative-0319` | paste | list | `__negative__:list` | `markdown` | 0.636208 |
| `holdout-dedicated-paste-negative-0322` | paste | list | `__negative__:list` | `markdown` | 0.615896 |
| `holdout-dedicated-paste-negative-0330` | paste | prose | `__negative__:prose` | `markdown` | 0.504640 |
| `holdout-dedicated-paste-negative-0331` | paste | list | `__negative__:list` | `markdown` | 0.466644 |
| `holdout-dedicated-paste-negative-0340` | paste | list | `__negative__:list` | `markdown` | 0.459709 |
| `holdout-dedicated-paste-negative-0343` | paste | list | `__negative__:list` | `markdown` | 0.615877 |
| `holdout-dedicated-paste-negative-0346` | paste | list | `__negative__:list` | `markdown` | 0.589026 |
| `holdout-dedicated-paste-negative-0349` | paste | list | `__negative__:list` | `haskell` | 0.404816 |
| `holdout-dedicated-paste-negative-0354` | paste | prose | `__negative__:prose` | `markdown` | 0.441882 |
| `holdout-dedicated-paste-negative-0355` | paste | list | `__negative__:list` | `markdown` | 0.447863 |
| `holdout-dedicated-paste-negative-0361` | paste | list | `__negative__:list` | `markdown` | 0.615048 |
| `holdout-dedicated-paste-negative-0364` | paste | list | `__negative__:list` | `markdown` | 0.483629 |
| `holdout-dedicated-paste-negative-0367` | paste | list | `__negative__:list` | `markdown` | 0.643270 |
| `holdout-dedicated-paste-negative-0370` | paste | list | `__negative__:list` | `markdown` | 0.644548 |
| `holdout-dedicated-paste-negative-0373` | paste | list | `__negative__:list` | `haskell` | 0.401401 |
| `holdout-dedicated-paste-negative-0378` | paste | prose | `__negative__:prose` | `markdown` | 0.473508 |
| `holdout-dedicated-paste-negative-0379` | paste | list | `__negative__:list` | `markdown` | 0.483024 |
| `holdout-dedicated-paste-negative-0385` | paste | list | `__negative__:list` | `markdown` | 0.550710 |
| `holdout-dedicated-paste-negative-0388` | paste | list | `__negative__:list` | `markdown` | 0.403031 |
| `holdout-dedicated-paste-negative-0391` | paste | list | `__negative__:list` | `markdown` | 0.657357 |
| `holdout-dedicated-paste-negative-0394` | paste | list | `__negative__:list` | `markdown` | 0.630580 |
| `holdout-dedicated-paste-negative-0402` | paste | prose | `__negative__:prose` | `markdown` | 0.477321 |
| `holdout-dedicated-paste-negative-0403` | paste | list | `__negative__:list` | `markdown` | 0.500700 |
| `holdout-dedicated-paste-negative-0412` | paste | list | `__negative__:list` | `markdown` | 0.413083 |
| `holdout-dedicated-paste-negative-0415` | paste | list | `__negative__:list` | `markdown` | 0.638016 |
| `holdout-dedicated-paste-negative-0418` | paste | list | `__negative__:list` | `markdown` | 0.613014 |
| `holdout-dedicated-paste-negative-0426` | paste | prose | `__negative__:prose` | `markdown` | 0.451323 |
| `holdout-dedicated-paste-negative-0427` | paste | list | `__negative__:list` | `markdown` | 0.480790 |
| `holdout-dedicated-paste-negative-0433` | paste | list | `__negative__:list` | `markdown` | 0.545176 |
| `holdout-dedicated-paste-negative-0436` | paste | list | `__negative__:list` | `markdown` | 0.472128 |
| `holdout-dedicated-paste-negative-0439` | paste | list | `__negative__:list` | `markdown` | 0.613438 |
| `holdout-dedicated-paste-negative-0442` | paste | list | `__negative__:list` | `markdown` | 0.645623 |
| `holdout-dedicated-paste-negative-0450` | paste | prose | `__negative__:prose` | `markdown` | 0.482391 |
| `holdout-dedicated-paste-negative-0451` | paste | list | `__negative__:list` | `markdown` | 0.464225 |
| `holdout-dedicated-paste-negative-0457` | paste | list | `__negative__:list` | `markdown` | 0.601669 |
| `holdout-dedicated-paste-negative-0460` | paste | list | `__negative__:list` | `markdown` | 0.464808 |
| `holdout-dedicated-paste-negative-0463` | paste | list | `__negative__:list` | `markdown` | 0.655183 |
| `holdout-dedicated-paste-negative-0466` | paste | list | `__negative__:list` | `markdown` | 0.640713 |
| `holdout-dedicated-paste-negative-0469` | paste | list | `__negative__:list` | `haskell` | 0.435732 |
| `holdout-dedicated-paste-negative-0474` | paste | prose | `__negative__:prose` | `markdown` | 0.463707 |
| `holdout-dedicated-paste-negative-0475` | paste | list | `__negative__:list` | `markdown` | 0.487941 |
| `holdout-dedicated-paste-negative-0481` | paste | list | `__negative__:list` | `markdown` | 0.643150 |
| `holdout-dedicated-paste-negative-0487` | paste | list | `__negative__:list` | `markdown` | 0.634109 |
| `holdout-dedicated-paste-negative-0490` | paste | list | `__negative__:list` | `markdown` | 0.576880 |
| `holdout-dedicated-paste-negative-0498` | paste | prose | `__negative__:prose` | `markdown` | 0.432366 |
| `holdout-dedicated-paste-negative-0499` | paste | list | `__negative__:list` | `markdown` | 0.487115 |
| `holdout-dedicated-paste-negative-0505` | paste | list | `__negative__:list` | `markdown` | 0.595045 |
| `holdout-dedicated-paste-negative-0508` | paste | list | `__negative__:list` | `markdown` | 0.439898 |
| `holdout-dedicated-paste-negative-0511` | paste | list | `__negative__:list` | `markdown` | 0.639120 |
| `holdout-dedicated-paste-negative-0514` | paste | list | `__negative__:list` | `markdown` | 0.614355 |
| `holdout-dedicated-paste-negative-0522` | paste | prose | `__negative__:prose` | `markdown` | 0.453863 |
| `holdout-dedicated-paste-negative-0523` | paste | list | `__negative__:list` | `markdown` | 0.453465 |
| `holdout-dedicated-paste-negative-0529` | paste | list | `__negative__:list` | `markdown` | 0.602121 |
| `holdout-dedicated-paste-negative-0532` | paste | list | `__negative__:list` | `markdown` | 0.502297 |
| `holdout-dedicated-paste-negative-0535` | paste | list | `__negative__:list` | `markdown` | 0.627124 |
| `holdout-dedicated-paste-negative-0538` | paste | list | `__negative__:list` | `markdown` | 0.638080 |
| `holdout-dedicated-paste-negative-0541` | paste | list | `__negative__:list` | `haskell` | 0.409567 |
| `holdout-dedicated-paste-negative-0546` | paste | prose | `__negative__:prose` | `markdown` | 0.488878 |
| `holdout-dedicated-paste-negative-0547` | paste | list | `__negative__:list` | `markdown` | 0.459964 |
| `holdout-dedicated-paste-negative-0553` | paste | list | `__negative__:list` | `markdown` | 0.630113 |
| `holdout-dedicated-paste-negative-0559` | paste | list | `__negative__:list` | `markdown` | 0.662051 |
| `holdout-dedicated-paste-negative-0562` | paste | list | `__negative__:list` | `markdown` | 0.668218 |
| `holdout-dedicated-paste-negative-0570` | paste | prose | `__negative__:prose` | `markdown` | 0.462839 |
| `holdout-dedicated-paste-negative-0571` | paste | list | `__negative__:list` | `markdown` | 0.440919 |
| `holdout-dedicated-paste-negative-0577` | paste | list | `__negative__:list` | `markdown` | 0.606529 |
| `holdout-dedicated-paste-negative-0580` | paste | list | `__negative__:list` | `markdown` | 0.480839 |
| `holdout-dedicated-paste-negative-0583` | paste | list | `__negative__:list` | `markdown` | 0.631822 |
| `holdout-dedicated-paste-negative-0586` | paste | list | `__negative__:list` | `markdown` | 0.640527 |
| `holdout-dedicated-paste-negative-0589` | paste | list | `__negative__:list` | `haskell` | 0.415034 |
| `holdout-dedicated-paste-negative-0594` | paste | prose | `__negative__:prose` | `markdown` | 0.457573 |
| `holdout-dedicated-paste-negative-0595` | paste | list | `__negative__:list` | `markdown` | 0.448266 |
| `holdout-dedicated-paste-negative-0601` | paste | list | `__negative__:list` | `markdown` | 0.557474 |
| `holdout-dedicated-paste-negative-0604` | paste | list | `__negative__:list` | `markdown` | 0.403601 |
| `holdout-dedicated-paste-negative-0607` | paste | list | `__negative__:list` | `markdown` | 0.606754 |
| `holdout-dedicated-paste-negative-0610` | paste | list | `__negative__:list` | `markdown` | 0.625991 |
| `holdout-dedicated-paste-negative-0618` | paste | prose | `__negative__:prose` | `markdown` | 0.436158 |
| `holdout-dedicated-paste-negative-0619` | paste | list | `__negative__:list` | `markdown` | 0.439949 |
| `holdout-dedicated-paste-negative-0625` | paste | list | `__negative__:list` | `markdown` | 0.531834 |
| `holdout-dedicated-paste-negative-0631` | paste | list | `__negative__:list` | `markdown` | 0.678195 |
| `holdout-dedicated-paste-negative-0634` | paste | list | `__negative__:list` | `markdown` | 0.590290 |
| `holdout-dedicated-paste-negative-0642` | paste | prose | `__negative__:prose` | `markdown` | 0.473990 |
| `holdout-dedicated-paste-negative-0643` | paste | list | `__negative__:list` | `markdown` | 0.458926 |
| `holdout-dedicated-paste-negative-0649` | paste | list | `__negative__:list` | `markdown` | 0.558903 |
| `holdout-dedicated-paste-negative-0655` | paste | list | `__negative__:list` | `markdown` | 0.620216 |
| `holdout-dedicated-paste-negative-0658` | paste | list | `__negative__:list` | `markdown` | 0.604039 |
| `holdout-dedicated-paste-negative-0661` | paste | list | `__negative__:list` | `haskell` | 0.413411 |
| `holdout-dedicated-paste-negative-0666` | paste | prose | `__negative__:prose` | `markdown` | 0.437051 |
| `holdout-dedicated-paste-negative-0667` | paste | list | `__negative__:list` | `markdown` | 0.458187 |
| `holdout-dedicated-paste-negative-0679` | paste | list | `__negative__:list` | `markdown` | 0.671863 |
| `holdout-dedicated-paste-negative-0682` | paste | list | `__negative__:list` | `markdown` | 0.578703 |
| `holdout-dedicated-paste-negative-0690` | paste | prose | `__negative__:prose` | `markdown` | 0.459943 |
| `holdout-dedicated-paste-negative-0691` | paste | list | `__negative__:list` | `markdown` | 0.485081 |
| `holdout-dedicated-paste-negative-0697` | paste | list | `__negative__:list` | `markdown` | 0.570950 |
| `holdout-dedicated-paste-negative-0703` | paste | list | `__negative__:list` | `markdown` | 0.630756 |
| `holdout-dedicated-paste-negative-0706` | paste | list | `__negative__:list` | `markdown` | 0.616958 |
| `holdout-dedicated-paste-negative-0714` | paste | prose | `__negative__:prose` | `markdown` | 0.468858 |
| `holdout-dedicated-paste-negative-0715` | paste | list | `__negative__:list` | `markdown` | 0.460694 |
| `holdout-dedicated-paste-negative-0721` | paste | list | `__negative__:list` | `markdown` | 0.589391 |
| `holdout-dedicated-paste-negative-0727` | paste | list | `__negative__:list` | `markdown` | 0.661994 |
| `holdout-dedicated-paste-negative-0730` | paste | list | `__negative__:list` | `markdown` | 0.634760 |
| `holdout-dedicated-paste-negative-0738` | paste | prose | `__negative__:prose` | `markdown` | 0.461980 |
| `holdout-dedicated-paste-negative-0739` | paste | list | `__negative__:list` | `markdown` | 0.480784 |
| `holdout-dedicated-paste-negative-0745` | paste | list | `__negative__:list` | `markdown` | 0.565745 |
| `holdout-dedicated-paste-negative-0748` | paste | list | `__negative__:list` | `markdown` | 0.432514 |
| `holdout-dedicated-paste-negative-0751` | paste | list | `__negative__:list` | `markdown` | 0.653999 |
| `holdout-dedicated-paste-negative-0754` | paste | list | `__negative__:list` | `markdown` | 0.618334 |
| `holdout-dedicated-paste-negative-0762` | paste | prose | `__negative__:prose` | `markdown` | 0.460550 |
| `holdout-dedicated-paste-negative-0763` | paste | list | `__negative__:list` | `markdown` | 0.493499 |
| `holdout-dedicated-paste-negative-0769` | paste | list | `__negative__:list` | `markdown` | 0.635205 |
| `holdout-dedicated-paste-negative-0772` | paste | list | `__negative__:list` | `markdown` | 0.440608 |
| `holdout-dedicated-paste-negative-0775` | paste | list | `__negative__:list` | `markdown` | 0.630255 |
| `holdout-dedicated-paste-negative-0778` | paste | list | `__negative__:list` | `markdown` | 0.635625 |
| `holdout-dedicated-paste-negative-0786` | paste | prose | `__negative__:prose` | `markdown` | 0.464161 |
| `holdout-dedicated-paste-negative-0787` | paste | list | `__negative__:list` | `markdown` | 0.453186 |
| `holdout-dedicated-paste-negative-0793` | paste | list | `__negative__:list` | `markdown` | 0.576306 |
| `holdout-dedicated-paste-negative-0796` | paste | list | `__negative__:list` | `markdown` | 0.441922 |
| `holdout-dedicated-paste-negative-0799` | paste | list | `__negative__:list` | `markdown` | 0.624808 |
| `holdout-dedicated-paste-negative-0802` | paste | list | `__negative__:list` | `markdown` | 0.608467 |
| `holdout-dedicated-paste-negative-0810` | paste | prose | `__negative__:prose` | `markdown` | 0.452590 |
| `holdout-dedicated-paste-negative-0811` | paste | list | `__negative__:list` | `markdown` | 0.476360 |
| `holdout-dedicated-paste-negative-0817` | paste | list | `__negative__:list` | `markdown` | 0.510383 |
| `holdout-dedicated-paste-negative-0820` | paste | list | `__negative__:list` | `markdown` | 0.432288 |
| `holdout-dedicated-paste-negative-0823` | paste | list | `__negative__:list` | `markdown` | 0.657107 |
| `holdout-dedicated-paste-negative-0826` | paste | list | `__negative__:list` | `markdown` | 0.620017 |
| `holdout-dedicated-paste-negative-0829` | paste | list | `__negative__:list` | `haskell` | 0.402946 |
| `holdout-dedicated-paste-negative-0834` | paste | prose | `__negative__:prose` | `markdown` | 0.441223 |
| `holdout-dedicated-paste-negative-0835` | paste | list | `__negative__:list` | `markdown` | 0.507139 |
| `holdout-dedicated-paste-negative-0841` | paste | list | `__negative__:list` | `markdown` | 0.573079 |
| `holdout-dedicated-paste-negative-0844` | paste | list | `__negative__:list` | `markdown` | 0.400290 |
| `holdout-dedicated-paste-negative-0847` | paste | list | `__negative__:list` | `markdown` | 0.649014 |
| `holdout-dedicated-paste-negative-0850` | paste | list | `__negative__:list` | `markdown` | 0.613568 |
| `holdout-dedicated-paste-negative-0858` | paste | prose | `__negative__:prose` | `markdown` | 0.442036 |
| `holdout-dedicated-paste-negative-0859` | paste | list | `__negative__:list` | `markdown` | 0.483120 |
| `holdout-dedicated-paste-negative-0865` | paste | list | `__negative__:list` | `markdown` | 0.618482 |
| `holdout-dedicated-paste-negative-0868` | paste | list | `__negative__:list` | `markdown` | 0.459119 |
| `holdout-dedicated-paste-negative-0871` | paste | list | `__negative__:list` | `markdown` | 0.644668 |
| `holdout-dedicated-paste-negative-0874` | paste | list | `__negative__:list` | `markdown` | 0.670822 |
| `holdout-dedicated-paste-negative-0882` | paste | prose | `__negative__:prose` | `markdown` | 0.476246 |
| `holdout-dedicated-paste-negative-0883` | paste | list | `__negative__:list` | `markdown` | 0.440755 |
| `holdout-dedicated-paste-negative-0889` | paste | list | `__negative__:list` | `markdown` | 0.530224 |
| `holdout-dedicated-paste-negative-0895` | paste | list | `__negative__:list` | `markdown` | 0.629423 |
| `holdout-dedicated-paste-negative-0898` | paste | list | `__negative__:list` | `markdown` | 0.599361 |
| `holdout-dedicated-paste-negative-0906` | paste | prose | `__negative__:prose` | `markdown` | 0.429760 |
| `holdout-dedicated-paste-negative-0907` | paste | list | `__negative__:list` | `markdown` | 0.470961 |
| `holdout-dedicated-paste-negative-0913` | paste | list | `__negative__:list` | `markdown` | 0.651625 |
| `holdout-dedicated-paste-negative-0916` | paste | list | `__negative__:list` | `markdown` | 0.478047 |
| `holdout-dedicated-paste-negative-0919` | paste | list | `__negative__:list` | `markdown` | 0.625608 |
| `holdout-dedicated-paste-negative-0922` | paste | list | `__negative__:list` | `markdown` | 0.595485 |
| `holdout-dedicated-paste-negative-0925` | paste | list | `__negative__:list` | `haskell` | 0.429650 |
| `holdout-dedicated-paste-negative-0930` | paste | prose | `__negative__:prose` | `markdown` | 0.491046 |
| `holdout-dedicated-paste-negative-0931` | paste | list | `__negative__:list` | `markdown` | 0.473009 |
| `holdout-dedicated-paste-negative-0937` | paste | list | `__negative__:list` | `markdown` | 0.579302 |
| `holdout-dedicated-paste-negative-0943` | paste | list | `__negative__:list` | `markdown` | 0.660026 |
| `holdout-dedicated-paste-negative-0946` | paste | list | `__negative__:list` | `markdown` | 0.647400 |
| `holdout-dedicated-paste-negative-0954` | paste | prose | `__negative__:prose` | `markdown` | 0.437059 |
| `holdout-dedicated-paste-negative-0955` | paste | list | `__negative__:list` | `markdown` | 0.472600 |
| `holdout-dedicated-paste-negative-0961` | paste | list | `__negative__:list` | `markdown` | 0.567320 |
| `holdout-dedicated-paste-negative-0964` | paste | list | `__negative__:list` | `markdown` | 0.474763 |
| `holdout-dedicated-paste-negative-0967` | paste | list | `__negative__:list` | `markdown` | 0.647232 |
| `holdout-dedicated-paste-negative-0970` | paste | list | `__negative__:list` | `markdown` | 0.622004 |
| `holdout-dedicated-paste-negative-0973` | paste | list | `__negative__:list` | `haskell` | 0.405390 |
| `holdout-dedicated-paste-negative-0978` | paste | prose | `__negative__:prose` | `markdown` | 0.469423 |
| `holdout-dedicated-paste-negative-0979` | paste | list | `__negative__:list` | `markdown` | 0.471568 |
| `holdout-dedicated-paste-negative-0985` | paste | list | `__negative__:list` | `markdown` | 0.527719 |
| `holdout-dedicated-paste-negative-0991` | paste | list | `__negative__:list` | `markdown` | 0.641608 |
| `holdout-dedicated-paste-negative-0994` | paste | list | `__negative__:list` | `markdown` | 0.568434 |
| `holdout-dedicated-paste-negative-1002` | paste | prose | `__negative__:prose` | `markdown` | 0.414457 |
| `holdout-dedicated-paste-negative-1003` | paste | list | `__negative__:list` | `markdown` | 0.437178 |
| `holdout-dedicated-paste-negative-1009` | paste | list | `__negative__:list` | `markdown` | 0.568724 |
| `holdout-dedicated-paste-negative-1012` | paste | list | `__negative__:list` | `markdown` | 0.456163 |
| `holdout-dedicated-paste-negative-1015` | paste | list | `__negative__:list` | `markdown` | 0.631923 |
| `holdout-dedicated-paste-negative-1018` | paste | list | `__negative__:list` | `markdown` | 0.638687 |
| `holdout-dedicated-paste-negative-1026` | paste | prose | `__negative__:prose` | `markdown` | 0.462386 |
| `holdout-dedicated-paste-negative-1027` | paste | list | `__negative__:list` | `markdown` | 0.499709 |
| `holdout-dedicated-paste-negative-1033` | paste | list | `__negative__:list` | `markdown` | 0.520537 |
| `holdout-dedicated-paste-negative-1039` | paste | list | `__negative__:list` | `markdown` | 0.665460 |
| `holdout-dedicated-paste-negative-1042` | paste | list | `__negative__:list` | `markdown` | 0.553099 |
| `holdout-dedicated-paste-negative-1050` | paste | prose | `__negative__:prose` | `markdown` | 0.422033 |
| `holdout-dedicated-paste-negative-1051` | paste | list | `__negative__:list` | `markdown` | 0.529847 |
| `holdout-dedicated-paste-negative-1063` | paste | list | `__negative__:list` | `markdown` | 0.614399 |
| `holdout-dedicated-paste-negative-1066` | paste | list | `__negative__:list` | `markdown` | 0.583169 |
| `holdout-dedicated-paste-negative-1074` | paste | prose | `__negative__:prose` | `markdown` | 0.441094 |
| `holdout-dedicated-paste-negative-1075` | paste | list | `__negative__:list` | `markdown` | 0.466686 |
| `holdout-dedicated-paste-negative-1081` | paste | list | `__negative__:list` | `markdown` | 0.597696 |
| `holdout-dedicated-paste-negative-1087` | paste | list | `__negative__:list` | `markdown` | 0.655258 |
| `holdout-dedicated-paste-negative-1090` | paste | list | `__negative__:list` | `markdown` | 0.628470 |
| `holdout-dedicated-paste-negative-1098` | paste | prose | `__negative__:prose` | `markdown` | 0.448075 |
| `holdout-dedicated-paste-negative-1099` | paste | list | `__negative__:list` | `markdown` | 0.475384 |
| `holdout-dedicated-paste-negative-1105` | paste | list | `__negative__:list` | `markdown` | 0.555354 |
| `holdout-dedicated-paste-negative-1108` | paste | list | `__negative__:list` | `markdown` | 0.436479 |
| `holdout-dedicated-paste-negative-1111` | paste | list | `__negative__:list` | `markdown` | 0.645240 |
| `holdout-dedicated-paste-negative-1114` | paste | list | `__negative__:list` | `markdown` | 0.618745 |
| `holdout-dedicated-paste-negative-1122` | paste | prose | `__negative__:prose` | `markdown` | 0.441796 |
| `holdout-dedicated-paste-negative-1123` | paste | list | `__negative__:list` | `markdown` | 0.484880 |
| `holdout-dedicated-paste-negative-1129` | paste | list | `__negative__:list` | `markdown` | 0.535896 |
| `holdout-dedicated-paste-negative-1135` | paste | list | `__negative__:list` | `markdown` | 0.678671 |
| `holdout-dedicated-paste-negative-1138` | paste | list | `__negative__:list` | `markdown` | 0.601835 |
| `holdout-dedicated-paste-negative-1146` | paste | prose | `__negative__:prose` | `markdown` | 0.420593 |
| `holdout-dedicated-paste-negative-1147` | paste | list | `__negative__:list` | `markdown` | 0.500360 |
| `holdout-dedicated-paste-negative-1153` | paste | list | `__negative__:list` | `markdown` | 0.585036 |
| `holdout-dedicated-paste-negative-1156` | paste | list | `__negative__:list` | `markdown` | 0.460150 |
| `holdout-dedicated-paste-negative-1159` | paste | list | `__negative__:list` | `markdown` | 0.658230 |
| `holdout-dedicated-paste-negative-1162` | paste | list | `__negative__:list` | `markdown` | 0.669735 |
| `holdout-dedicated-paste-negative-1170` | paste | prose | `__negative__:prose` | `markdown` | 0.473513 |
| `holdout-dedicated-paste-negative-1171` | paste | list | `__negative__:list` | `markdown` | 0.509583 |
| `holdout-dedicated-paste-negative-1177` | paste | list | `__negative__:list` | `markdown` | 0.623597 |
| `holdout-dedicated-paste-negative-1183` | paste | list | `__negative__:list` | `markdown` | 0.677606 |
| `holdout-dedicated-paste-negative-1186` | paste | list | `__negative__:list` | `markdown` | 0.620558 |
| `holdout-dedicated-paste-negative-1194` | paste | prose | `__negative__:prose` | `markdown` | 0.444777 |
| `holdout-dedicated-paste-negative-1195` | paste | list | `__negative__:list` | `markdown` | 0.515170 |
| `holdout-paste-code-0000` | paste | code | `rust` | `javascript` | 0.467210 |
| `holdout-paste-code-0012` | paste | code | `rust` | `javascript` | 0.512696 |
| `holdout-paste-code-0024` | paste | code | `rust` | `javascript` | 0.468072 |
| `holdout-paste-code-0036` | paste | code | `rust` | `javascript` | 0.499325 |
| `holdout-paste-code-0048` | paste | code | `rust` | `__abstain__` | 0.408447 |
| `holdout-paste-code-0060` | paste | code | `rust` | `javascript` | 0.493257 |
| `holdout-paste-code-0063` | paste | code | `typescript` | `__abstain__` | 0.436186 |
| `holdout-paste-code-0064` | paste | code | `swift` | `__abstain__` | 0.348483 |
| `holdout-paste-code-0072` | paste | code | `rust` | `javascript` | 0.443947 |
| `holdout-paste-code-0076` | paste | code | `swift` | `__abstain__` | 0.332574 |
| `holdout-paste-code-0084` | paste | code | `rust` | `javascript` | 0.521586 |
| `holdout-paste-code-0088` | paste | code | `swift` | `__abstain__` | 0.323237 |
| `holdout-paste-code-0096` | paste | code | `rust` | `__abstain__` | 0.424187 |
| `holdout-paste-code-0108` | paste | code | `rust` | `javascript` | 0.470227 |
| `holdout-paste-code-0112` | paste | code | `swift` | `__abstain__` | 0.368525 |

## Artifact metadata

- Registry crate checksum SHA-256: `5f89b0929539eaee70109704ae4e345df438be6ab02e4dc8ac060e05098ad1b7`
- VCS revision: `13b5cbf7b934fdbd4be0bb7437faeb03124700de`
- Model SHA-256: `8493d2d3757572c8661141e414b1c0755aa08d4c4e5382dfbbc6b73b02d89083`
- Model size: 47840 bytes
- Verification: recorded registry artifact metadata; not re-verified at runtime

All raw ranked values are available in `cases.jsonl`. This report is evidence collection, not shipping approval.
