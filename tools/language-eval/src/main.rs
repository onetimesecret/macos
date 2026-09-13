//! Non-shipping synthetic evaluation harness for `betlang`.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::env;
use std::error::Error;
use std::fmt::Write as _;
use std::fs::{self, File};
use std::io::{self, BufWriter, Write as _};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::time::{Duration, Instant};

const TIMED_CHILD_ENV: &str = "LANGUAGE_EVAL_TIMED_CHILD";
const CRATE_CHECKSUM: &str = "5f89b0929539eaee70109704ae4e345df438be6ab02e4dc8ac060e05098ad1b7";
const VCS_REVISION: &str = "13b5cbf7b934fdbd4be0bb7437faeb03124700de";
const MODEL_SHA256: &str = "8493d2d3757572c8661141e414b1c0755aa08d4c4e5382dfbbc6b73b02d89083";
const MODEL_SIZE_BYTES: u64 = 47_840;

type AnyError = Box<dyn Error>;

#[derive(Debug, Deserialize)]
struct Corpus {
    schema_version: u32,
    cases: Vec<CorpusCase>,
    families: Vec<Family>,
}

#[derive(Clone, Debug, Deserialize)]
struct CorpusCase {
    id: String,
    split: Split,
    surface: String,
    kind: String,
    expected: Option<String>,
    useful_code: bool,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    hex: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum Split {
    Tune,
    Holdout,
}

impl Split {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Tune => "tune",
            Self::Holdout => "holdout",
        }
    }
}

#[derive(Debug, Deserialize)]
struct Family {
    id_prefix: String,
    split: Split,
    generator: String,
    count: usize,
    #[serde(default)]
    start_index: usize,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct Thresholds {
    minimum_non_whitespace_bytes: usize,
    minimum_top_score: f64,
    minimum_top_two_margin: f64,
    maximum_input_bytes: usize,
}

impl Thresholds {
    fn validate(&self) -> Result<(), AnyError> {
        if !self.minimum_top_score.is_finite()
            || !self.minimum_top_two_margin.is_finite()
            || !(0.0..=1.0).contains(&self.minimum_top_score)
            || !(0.0..=1.0).contains(&self.minimum_top_two_margin)
        {
            return Err(invalid(
                "score and margin thresholds must be finite values in [0, 1]",
            ));
        }
        if self.minimum_non_whitespace_bytes > self.maximum_input_bytes {
            return Err(invalid(
                "minimum_non_whitespace_bytes cannot exceed maximum_input_bytes",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SplitFilter {
    All,
    Tune,
    Holdout,
}

impl SplitFilter {
    fn includes(self, split: Split) -> bool {
        matches!(self, Self::All)
            || matches!(
                (self, split),
                (Self::Tune, Split::Tune) | (Self::Holdout, Split::Holdout)
            )
    }

    const fn as_str(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::Tune => "tune",
            Self::Holdout => "holdout",
        }
    }
}

#[derive(Debug)]
struct EvaluateArgs {
    corpus: PathBuf,
    thresholds: PathBuf,
    split: SplitFilter,
    output_dir: PathBuf,
    warm_iterations: usize,
}

#[derive(Debug)]
enum Cli {
    Evaluate(EvaluateArgs),
    Help,
}

#[derive(Clone, Debug)]
struct EvalCase {
    id: String,
    split: Split,
    surface: String,
    kind: String,
    expected: Option<String>,
    useful_code: bool,
    input: Vec<u8>,
}

#[derive(Clone, Debug, Serialize)]
struct RankedValue {
    score: f64,
    slug: String,
}

#[derive(Clone, Debug, Serialize)]
struct CaseResult {
    id: String,
    split: String,
    surface: String,
    kind: String,
    expected: Option<String>,
    useful_code: bool,
    input_bytes: usize,
    non_whitespace_bytes: usize,
    eligible: bool,
    accepted: Option<String>,
    abstention_reason: Option<String>,
    inference_nanoseconds: Option<u64>,
    ranked: Vec<RankedValue>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct Rate {
    numerator: u64,
    denominator: u64,
    rate: Option<f64>,
    wilson_95_percent: Option<ConfidenceInterval>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct ConfidenceInterval {
    lower: f64,
    upper: f64,
}

impl Rate {
    fn new(numerator: u64, denominator: u64) -> Self {
        let rate = (denominator != 0).then_some(numerator as f64 / denominator as f64);
        Self {
            numerator,
            denominator,
            rate,
            wilson_95_percent: rate.map(|rate| wilson_interval(rate, denominator)),
        }
    }
}

fn wilson_interval(rate: f64, denominator: u64) -> ConfidenceInterval {
    const Z: f64 = 1.959_963_984_540_054;
    let count = denominator as f64;
    let denominator = 1.0 + Z * Z / count;
    let center = (rate + Z * Z / (2.0 * count)) / denominator;
    let half_width =
        Z * ((rate * (1.0 - rate) / count + Z * Z / (4.0 * count * count)).sqrt()) / denominator;
    ConfidenceInterval {
        lower: if rate == 0.0 {
            0.0
        } else {
            (center - half_width).max(0.0)
        },
        upper: if rate == 1.0 {
            1.0
        } else {
            (center + half_width).min(1.0)
        },
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct Metrics {
    total_cases: u64,
    eligible_cases: u64,
    useful_code_cases: u64,
    eligible_useful_code_cases: u64,
    accepted_cases: u64,
    accepted_precision: Rate,
    exact_label_precision_where_defined: Rate,
    useful_code_coverage: Rate,
    exact_useful_code_coverage: Rate,
    abstention: Rate,
    negative_false_conversions: Rate,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct LatencyStats {
    samples: u64,
    p50_nanoseconds: Option<u64>,
    p95_nanoseconds: Option<u64>,
    p99_nanoseconds: Option<u64>,
    max_nanoseconds: Option<u64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct ArtifactMetadata {
    betlang_version: String,
    registry_crate_checksum_sha256: String,
    vcs_revision: String,
    model_sha256: String,
    model_size_bytes: u64,
    verification: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct ProcessMemory {
    metric: String,
    bytes: u64,
    source: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct RunMetadata {
    os: String,
    arch: String,
    profile: String,
    package: String,
    executable_size_bytes: u64,
    process_max_rss_whole_process_proxy: Option<ProcessMemory>,
    artifact: ArtifactMetadata,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct ConfusionCase {
    id: String,
    surface: String,
    kind: String,
    expected: String,
    outcome: String,
    top_score: Option<f64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct Report {
    schema_version: u32,
    split: String,
    thresholds: Thresholds,
    metadata: RunMetadata,
    metrics: Metrics,
    by_surface: BTreeMap<String, Metrics>,
    by_kind: BTreeMap<String, Metrics>,
    by_length_band: BTreeMap<String, Metrics>,
    confusion_matrix: BTreeMap<String, BTreeMap<String, u64>>,
    confusion_pairs: BTreeMap<String, u64>,
    detailed_confusion_cases: Vec<ConfusionCase>,
    cold_first_eligible_inference_nanoseconds: Option<u64>,
    warm_latency: LatencyStats,
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("language-eval: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), AnyError> {
    match parse_cli()? {
        Cli::Help => {
            print_help();
            Ok(())
        }
        Cli::Evaluate(args) => {
            if env::var_os(TIMED_CHILD_ENV).is_none() {
                run_timed(&args)
            } else {
                evaluate(&args)
            }
        }
    }
}

fn parse_cli() -> Result<Cli, AnyError> {
    let mut args = env::args().skip(1);
    let Some(command) = args.next() else {
        return Ok(Cli::Help);
    };
    if matches!(command.as_str(), "-h" | "--help" | "help") {
        return Ok(Cli::Help);
    }
    if command != "evaluate" {
        return Err(invalid(format!("unknown command: {command}")));
    }

    let mut corpus = None;
    let mut thresholds = None;
    let mut split = None;
    let mut output_dir = None;
    let mut warm_iterations = None;
    while let Some(flag) = args.next() {
        let value = args
            .next()
            .ok_or_else(|| invalid(format!("missing value for {flag}")))?;
        match flag.as_str() {
            "--corpus" => corpus = Some(PathBuf::from(value)),
            "--thresholds" => thresholds = Some(PathBuf::from(value)),
            "--split" => {
                split = Some(match value.as_str() {
                    "all" => SplitFilter::All,
                    "tune" => SplitFilter::Tune,
                    "holdout" => SplitFilter::Holdout,
                    _ => return Err(invalid("--split must be all, tune, or holdout")),
                });
            }
            "--output-dir" => output_dir = Some(PathBuf::from(value)),
            "--warm-iterations" => {
                warm_iterations = Some(value.parse::<usize>().map_err(|error| {
                    invalid(format!("invalid --warm-iterations value: {error}"))
                })?);
            }
            _ => return Err(invalid(format!("unknown option: {flag}"))),
        }
    }

    Ok(Cli::Evaluate(EvaluateArgs {
        corpus: corpus.ok_or_else(|| invalid("missing --corpus"))?,
        thresholds: thresholds.ok_or_else(|| invalid("missing --thresholds"))?,
        split: split.ok_or_else(|| invalid("missing --split"))?,
        output_dir: output_dir.ok_or_else(|| invalid("missing --output-dir"))?,
        warm_iterations: warm_iterations.ok_or_else(|| invalid("missing --warm-iterations"))?,
    }))
}

fn print_help() {
    println!(
        "Usage: language-eval evaluate --corpus PATH --thresholds PATH \\\n         --split all|tune|holdout --output-dir PATH --warm-iterations N"
    );
}

fn run_timed(args: &EvaluateArgs) -> Result<(), AnyError> {
    let executable = env::current_exe()?;
    let original_args: Vec<String> = env::args().skip(1).collect();
    let mut command = Command::new("/usr/bin/time");
    if cfg!(target_os = "macos") {
        command.arg("-l");
    } else {
        command.arg("-v");
    }
    let output = command
        .arg(&executable)
        .args(&original_args)
        .env(TIMED_CHILD_ENV, "1")
        .stdout(Stdio::inherit())
        .stderr(Stdio::piped())
        .output();

    let output = match output {
        Ok(output) => output,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            let status = Command::new(executable)
                .args(original_args)
                .env(TIMED_CHILD_ENV, "1")
                .status()?;
            if status.success() {
                return Ok(());
            }
            return Err(invalid(format!("evaluation child exited with {status}")));
        }
        Err(error) => return Err(error.into()),
    };

    let timing_stderr = String::from_utf8_lossy(&output.stderr);
    if !output.status.success() {
        eprint!("{timing_stderr}");
        return Err(invalid(format!(
            "evaluation child exited with {}",
            output.status
        )));
    }

    if let Some(memory) = parse_max_rss(&timing_stderr) {
        patch_process_memory(&args.output_dir, memory)?;
    }
    Ok(())
}

fn parse_max_rss(output: &str) -> Option<ProcessMemory> {
    for line in output.lines() {
        if line.contains("maximum resident set size") {
            let value = line
                .split_whitespace()
                .find_map(|word| word.parse::<u64>().ok())?;
            let bytes = if cfg!(target_os = "macos") {
                value
            } else {
                value.saturating_mul(1024)
            };
            return Some(ProcessMemory {
                metric: "maximum resident set size (whole-process proxy)".to_owned(),
                bytes,
                source: "/usr/bin/time".to_owned(),
            });
        }
    }
    None
}

fn patch_process_memory(output_dir: &Path, memory: ProcessMemory) -> Result<(), AnyError> {
    let report_path = output_dir.join("report.json");
    let mut report: Report = read_json(&report_path)?;
    report.metadata.process_max_rss_whole_process_proxy = Some(memory);
    write_report_files(output_dir, &report)
}

fn evaluate(args: &EvaluateArgs) -> Result<(), AnyError> {
    if cfg!(debug_assertions) {
        return Err(invalid(
            "evaluation must run in release mode; use cargo run --release",
        ));
    }
    let corpus: Corpus = read_json(&args.corpus)?;
    if corpus.schema_version != 2 {
        return Err(invalid(format!(
            "unsupported corpus schema version: {}",
            corpus.schema_version
        )));
    }
    let thresholds: Thresholds = read_json(&args.thresholds)?;
    thresholds.validate()?;
    let cases = expand_corpus(corpus)?
        .into_iter()
        .filter(|case| args.split.includes(case.split))
        .collect::<Vec<_>>();
    if cases.is_empty() {
        return Err(invalid("selected split contains no cases"));
    }

    fs::create_dir_all(&args.output_dir)?;
    let mut results = Vec::with_capacity(cases.len());
    let mut cold = None;
    let mut warm_input = None;
    for case in cases {
        let non_whitespace_bytes = count_non_whitespace(&case.input);
        let eligibility = eligibility_reason(&case.input, non_whitespace_bytes, &thresholds);
        let eligible = eligibility.is_none();
        let (ranked, elapsed) = if eligible {
            if warm_input.is_none() {
                warm_input = Some(case.input.clone());
            }
            let started = Instant::now();
            let detection = betlang::detect(&case.input);
            let elapsed = started.elapsed();
            if cold.is_none() {
                cold = Some(duration_ns(elapsed));
            }
            let ranked = collect_ranked(&detection)?;
            (ranked, Some(duration_ns(elapsed)))
        } else {
            (Vec::new(), None)
        };
        let (accepted, threshold_reason) = decide(&ranked, &thresholds);
        results.push(CaseResult {
            id: case.id,
            split: case.split.as_str().to_owned(),
            surface: case.surface,
            kind: case.kind,
            expected: case.expected,
            useful_code: case.useful_code,
            input_bytes: case.input.len(),
            non_whitespace_bytes,
            eligible,
            accepted,
            abstention_reason: eligibility.or(threshold_reason),
            inference_nanoseconds: elapsed,
            ranked,
        });
    }

    write_jsonl(&args.output_dir.join("cases.jsonl"), &results)?;
    let warm_latency = measure_warm(warm_input.as_deref(), args.warm_iterations)?;
    let report = build_report(args, thresholds, &results, cold, warm_latency)?;
    write_report_files(&args.output_dir, &report)?;
    println!(
        "{} cases; accepted precision {}; useful coverage {}; negative false conversions {}",
        report.metrics.total_cases,
        format_rate(&report.metrics.accepted_precision),
        format_rate(&report.metrics.useful_code_coverage),
        format_rate(&report.metrics.negative_false_conversions)
    );
    Ok(())
}

fn collect_ranked(detection: &betlang::Detection) -> Result<Vec<RankedValue>, AnyError> {
    detection
        .top_languages()
        .map(|(score, language)| {
            if !score.is_finite() {
                return Err(invalid(format!(
                    "model returned non-finite score for {}",
                    language.slug()
                )));
            }
            Ok(RankedValue {
                score: f64::from(score),
                slug: language.slug().to_owned(),
            })
        })
        .collect()
}

fn eligibility_reason(
    input: &[u8],
    non_whitespace_bytes: usize,
    thresholds: &Thresholds,
) -> Option<String> {
    if input.len() > thresholds.maximum_input_bytes {
        Some("input_exceeds_maximum_bytes".to_owned())
    } else if non_whitespace_bytes < thresholds.minimum_non_whitespace_bytes {
        Some("insufficient_non_whitespace_bytes".to_owned())
    } else {
        None
    }
}

fn decide(ranked: &[RankedValue], thresholds: &Thresholds) -> (Option<String>, Option<String>) {
    let Some(top) = ranked.first() else {
        return (None, Some("model_returned_no_rankings".to_owned()));
    };
    if top.score < thresholds.minimum_top_score {
        return (None, Some("top_score_below_minimum".to_owned()));
    }
    let second_score = ranked.get(1).map_or(0.0, |value| value.score);
    if top.score < second_score + thresholds.minimum_top_two_margin {
        return (None, Some("top_two_margin_below_minimum".to_owned()));
    }
    (Some(top.slug.clone()), None)
}

fn count_non_whitespace(input: &[u8]) -> usize {
    input
        .iter()
        .filter(|byte| !byte.is_ascii_whitespace())
        .count()
}

fn measure_warm(input: Option<&[u8]>, iterations: usize) -> Result<LatencyStats, AnyError> {
    let Some(input) = input else {
        return Ok(LatencyStats::default());
    };
    let mut samples = Vec::with_capacity(iterations);
    for _ in 0..iterations {
        let started = Instant::now();
        let detection = betlang::detect(input);
        let elapsed = started.elapsed();
        for (score, language) in detection.top_languages() {
            if !score.is_finite() {
                return Err(invalid(format!(
                    "model returned non-finite warm score for {}",
                    language.slug()
                )));
            }
        }
        samples.push(duration_ns(elapsed));
    }
    Ok(latency_stats(&mut samples))
}

fn latency_stats(samples: &mut [u64]) -> LatencyStats {
    samples.sort_unstable();
    LatencyStats {
        samples: samples.len() as u64,
        p50_nanoseconds: percentile(samples, 50),
        p95_nanoseconds: percentile(samples, 95),
        p99_nanoseconds: percentile(samples, 99),
        max_nanoseconds: samples.last().copied(),
    }
}

fn percentile(sorted: &[u64], percentile: usize) -> Option<u64> {
    if sorted.is_empty() {
        return None;
    }
    let rank = percentile.saturating_mul(sorted.len()).div_ceil(100);
    sorted.get(rank.saturating_sub(1)).copied()
}

fn duration_ns(duration: Duration) -> u64 {
    u64::try_from(duration.as_nanos()).unwrap_or(u64::MAX)
}

fn build_report(
    args: &EvaluateArgs,
    thresholds: Thresholds,
    results: &[CaseResult],
    cold: Option<u64>,
    warm_latency: LatencyStats,
) -> Result<Report, AnyError> {
    let mut confusion_matrix: BTreeMap<String, BTreeMap<String, u64>> = BTreeMap::new();
    let mut confusion_pairs = BTreeMap::new();
    let mut detailed_confusion_cases = Vec::new();

    for result in results {
        let expected = expected_confusion_label(result);
        let outcome = result.accepted.as_deref().unwrap_or("__abstain__");
        *confusion_matrix
            .entry(expected.clone())
            .or_default()
            .entry(outcome.to_owned())
            .or_default() += 1;
        if !is_expected_outcome(result) {
            *confusion_pairs
                .entry(format!("{expected} -> {outcome}"))
                .or_default() += 1;
            detailed_confusion_cases.push(ConfusionCase {
                id: result.id.clone(),
                surface: result.surface.clone(),
                kind: result.kind.clone(),
                expected,
                outcome: outcome.to_owned(),
                top_score: result.ranked.first().map(|value| value.score),
            });
        }
    }

    let by_surface = metrics_by(results, |result| result.surface.clone());
    let by_kind = metrics_by(results, |result| result.kind.clone());
    let by_length_band = metrics_by(results, |result| length_band(result.input_bytes).to_owned());
    let executable = env::current_exe()?;
    let executable_size_bytes = fs::metadata(executable)?.len();

    Ok(Report {
        schema_version: 3,
        split: args.split.as_str().to_owned(),
        thresholds,
        metadata: RunMetadata {
            os: env::consts::OS.to_owned(),
            arch: env::consts::ARCH.to_owned(),
            profile: if cfg!(debug_assertions) {
                "debug".to_owned()
            } else {
                "release".to_owned()
            },
            package: format!("language-eval {}", env!("CARGO_PKG_VERSION")),
            executable_size_bytes,
            process_max_rss_whole_process_proxy: None,
            artifact: ArtifactMetadata {
                betlang_version: "0.1.1".to_owned(),
                registry_crate_checksum_sha256: CRATE_CHECKSUM.to_owned(),
                vcs_revision: VCS_REVISION.to_owned(),
                model_sha256: MODEL_SHA256.to_owned(),
                model_size_bytes: MODEL_SIZE_BYTES,
                verification: "recorded registry artifact metadata; not re-verified at runtime"
                    .to_owned(),
            },
        },
        metrics: calculate_metrics(&results.iter().collect::<Vec<_>>()),
        by_surface,
        by_kind,
        by_length_band,
        confusion_matrix,
        confusion_pairs,
        detailed_confusion_cases,
        cold_first_eligible_inference_nanoseconds: cold,
        warm_latency,
    })
}

fn metrics_by(
    results: &[CaseResult],
    key: impl Fn(&CaseResult) -> String,
) -> BTreeMap<String, Metrics> {
    let mut grouped: BTreeMap<String, Vec<&CaseResult>> = BTreeMap::new();
    for result in results {
        grouped.entry(key(result)).or_default().push(result);
    }
    grouped
        .into_iter()
        .map(|(group, group_results)| (group, calculate_metrics(&group_results)))
        .collect()
}

fn length_band(input_bytes: usize) -> &'static str {
    match input_bytes {
        0..=19 => "000-019",
        20..=79 => "020-079",
        80..=255 => "080-255",
        _ => "256-plus",
    }
}

fn calculate_metrics(results: &[&CaseResult]) -> Metrics {
    let total = results.len() as u64;
    let eligible = results.iter().filter(|result| result.eligible).count() as u64;
    let useful = results.iter().filter(|result| result.useful_code).count() as u64;
    let eligible_useful = results
        .iter()
        .filter(|result| result.eligible && result.useful_code)
        .count() as u64;
    let accepted = results
        .iter()
        .filter(|result| result.accepted.is_some())
        .count() as u64;
    let accepted_useful = results
        .iter()
        .filter(|result| result.useful_code && result.accepted.is_some())
        .count() as u64;

    let accepted_defined = results
        .iter()
        .filter(|result| result.accepted.is_some() && result.expected.is_some())
        .count() as u64;
    let exact_defined = results
        .iter()
        .filter(|result| result.accepted.is_some() && exact_label_matches(result))
        .count() as u64;
    let useful_exact = results
        .iter()
        .filter(|result| result.useful_code && exact_label_matches(result))
        .count() as u64;
    let negatives = results.iter().filter(|result| !result.useful_code).count() as u64;
    let negative_conversions = results
        .iter()
        .filter(|result| !result.useful_code && result.accepted.is_some())
        .count() as u64;

    Metrics {
        total_cases: total,
        eligible_cases: eligible,
        useful_code_cases: useful,
        eligible_useful_code_cases: eligible_useful,
        accepted_cases: accepted,
        accepted_precision: Rate::new(accepted_useful, accepted),
        exact_label_precision_where_defined: Rate::new(exact_defined, accepted_defined),
        useful_code_coverage: Rate::new(accepted_useful, useful),
        exact_useful_code_coverage: Rate::new(useful_exact, useful),
        abstention: Rate::new(total - accepted, total),
        negative_false_conversions: Rate::new(negative_conversions, negatives),
    }
}

fn exact_label_matches(result: &CaseResult) -> bool {
    matches!(
        (&result.expected, &result.accepted),
        (Some(expected), Some(accepted)) if expected == accepted
    )
}

fn is_expected_outcome(result: &CaseResult) -> bool {
    exact_label_matches(result) || (result.expected.is_none() && result.accepted.is_none())
}

fn expected_confusion_label(result: &CaseResult) -> String {
    result
        .expected
        .clone()
        .unwrap_or_else(|| format!("__negative__:{}", result.kind))
}

fn expand_corpus(corpus: Corpus) -> Result<Vec<EvalCase>, AnyError> {
    let mut expanded = corpus
        .cases
        .into_iter()
        .map(convert_case)
        .collect::<Result<Vec<_>, _>>()?;
    for family in corpus.families {
        if family.generator != "paste_negative" {
            return Err(invalid(format!(
                "unknown family generator: {}",
                family.generator
            )));
        }
        for index in 0..family.count {
            expanded.push(generated_negative(&family, index));
        }
    }
    Ok(expanded)
}

fn convert_case(case: CorpusCase) -> Result<EvalCase, AnyError> {
    if !matches!(case.surface.as_str(), "paste" | "fence" | "file") {
        return Err(invalid(format!(
            "case {} has invalid product surface: {}",
            case.id, case.surface
        )));
    }
    if case.kind.is_empty() {
        return Err(invalid(format!("case {} has an empty kind", case.id)));
    }
    let input = match (case.text, case.hex) {
        (Some(text), None) => text.into_bytes(),
        (None, Some(hex)) => decode_hex(&hex)?,
        _ => {
            return Err(invalid(format!(
                "case {} must have exactly one input",
                case.id
            )));
        }
    };
    Ok(EvalCase {
        id: case.id,
        split: case.split,
        surface: case.surface,
        kind: case.kind,
        expected: case.expected,
        useful_code: case.useful_code,
        input,
    })
}

fn generated_negative(family: &Family, index: usize) -> EvalCase {
    let generation_index = family.start_index + index;
    let variant = generation_index % 10;
    let serial = generation_index / 10;
    let (kind, text) = match variant {
        0 => (
            "prose",
            format!("Reminder {serial}: bring the sample forms to the afternoon planning meeting."),
        ),
        1 => (
            "list",
            format!("Packing list {serial}:\n- notebook\n- reusable bottle\n- transit card"),
        ),
        2 => (
            "url",
            format!("https://example.invalid/archive/{serial}/summary?source=synthetic"),
        ),
        3 => (
            "credential-shaped",
            format!("demo_user_{serial}\nEXAMPLE-CREDENTIAL-{serial:06}-NOT-REAL"),
        ),
        4 => (
            "log",
            format!(
                "2026-02-03T12:{:02}:00Z INFO sample_job={serial} state=finished",
                serial % 60
            ),
        ),
        5 => (
            "markdown",
            format!(
                "## Session {serial}\n\n- Discuss schedule\n- Record decisions\n- Assign owners"
            ),
        ),
        6 => (
            "config-shaped",
            format!("Profile: Synthetic {serial}\nColor Scheme: Light\nAutomatic Updates: Enabled"),
        ),
        7 => (
            "mixed",
            format!(
                "Example {serial} says `mode: ready`; this is explanatory prose, not a configuration."
            ),
        ),
        8 => (
            "malformed",
            format!(
                "unfinished thought number {serial} {{ with stray punctuation [ and no program context"
            ),
        ),
        _ => (
            "binary",
            format!("GIF89a\0synthetic-binary-payload-{serial:06}\u{1}\u{2}"),
        ),
    };
    EvalCase {
        id: format!("{}-{index:04}", family.id_prefix),
        split: family.split,
        surface: "paste".to_owned(),
        kind: kind.to_owned(),
        expected: None,
        useful_code: false,
        input: text.into_bytes(),
    }
}

fn decode_hex(value: &str) -> Result<Vec<u8>, AnyError> {
    if !value.len().is_multiple_of(2) {
        return Err(invalid("hex input must have an even number of digits"));
    }
    (0..value.len())
        .step_by(2)
        .map(|index| {
            u8::from_str_radix(&value[index..index + 2], 16)
                .map_err(|error| invalid(format!("invalid hex input: {error}")))
        })
        .collect()
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<T, AnyError> {
    Ok(serde_json::from_reader(File::open(path)?)?)
}

fn write_jsonl(path: &Path, results: &[CaseResult]) -> Result<(), AnyError> {
    let mut writer = BufWriter::new(File::create(path)?);
    for result in results {
        serde_json::to_writer(&mut writer, result)?;
        writer.write_all(b"\n")?;
    }
    writer.flush()?;
    Ok(())
}

fn write_report_files(output_dir: &Path, report: &Report) -> Result<(), AnyError> {
    let json = serde_json::to_vec_pretty(report)?;
    fs::write(output_dir.join("report.json"), json)?;
    fs::write(output_dir.join("report.md"), report_markdown(report))?;
    Ok(())
}

fn report_markdown(report: &Report) -> String {
    let mut output = String::new();
    writeln!(output, "# Language evaluation report\n").expect("writing to a String cannot fail");
    writeln!(output, "- Split: `{}`", report.split).expect("writing to a String cannot fail");
    writeln!(
        output,
        "- Platform: `{}/{}`",
        report.metadata.os, report.metadata.arch
    )
    .expect("writing to a String cannot fail");
    writeln!(output, "- Profile: `{}`", report.metadata.profile)
        .expect("writing to a String cannot fail");
    writeln!(
        output,
        "- Executable size: {} bytes",
        report.metadata.executable_size_bytes
    )
    .expect("writing to a String cannot fail");
    match &report.metadata.process_max_rss_whole_process_proxy {
        Some(memory) => writeln!(
            output,
            "- Whole-process max RSS proxy: {} bytes ({})",
            memory.bytes, memory.source
        ),
        None => writeln!(output, "- Whole-process max RSS proxy: unavailable"),
    }
    .expect("writing to a String cannot fail");
    writeln!(
        output,
        "- Cold first eligible inference: {}",
        format_ns(report.cold_first_eligible_inference_nanoseconds)
    )
    .expect("writing to a String cannot fail");
    writeln!(
        output,
        "- Warm p50/p95/p99/max: {}/{}/{}/{}",
        format_ns(report.warm_latency.p50_nanoseconds),
        format_ns(report.warm_latency.p95_nanoseconds),
        format_ns(report.warm_latency.p99_nanoseconds),
        format_ns(report.warm_latency.max_nanoseconds)
    )
    .expect("writing to a String cannot fail");

    output.push_str("\n## Aggregate metrics\n\n");
    write_metrics_table(&mut output, &report.metrics);
    write_grouped_metrics(
        &mut output,
        "Metrics by product surface",
        "Surface",
        &report.by_surface,
    );
    write_grouped_metrics(
        &mut output,
        "Metrics by content kind",
        "Kind",
        &report.by_kind,
    );
    write_grouped_metrics(
        &mut output,
        "Metrics by input length",
        "Input bytes",
        &report.by_length_band,
    );

    output.push_str("\n## Confusion matrix\n\n| Expected | Outcome | Count |\n|---|---|---:|\n");
    for (expected, outcomes) in &report.confusion_matrix {
        for (outcome, count) in outcomes {
            writeln!(output, "| `{expected}` | `{outcome}` | {count} |")
                .expect("writing to a String cannot fail");
        }
    }

    output.push_str("\n## Confusion pairs\n\n| Pair | Count |\n|---|---:|\n");
    for (pair, count) in &report.confusion_pairs {
        writeln!(output, "| `{pair}` | {count} |").expect("writing to a String cannot fail");
    }
    output.push_str("\n## Detailed confusion cases\n\n| Case | Surface | Kind | Expected | Outcome | Top score |\n|---|---|---|---|---|---:|\n");
    for case in &report.detailed_confusion_cases {
        writeln!(
            output,
            "| `{}` | {} | {} | `{}` | `{}` | {} |",
            case.id,
            case.surface,
            case.kind,
            case.expected,
            case.outcome,
            case.top_score
                .map_or_else(|| "n/a".to_owned(), |score| format!("{score:.6}"))
        )
        .expect("writing to a String cannot fail");
    }
    output.push_str("\n## Artifact metadata\n\n");
    writeln!(output, "- Registry crate checksum SHA-256: `{CRATE_CHECKSUM}`\n- VCS revision: `{VCS_REVISION}`\n- Model SHA-256: `{MODEL_SHA256}`\n- Model size: {MODEL_SIZE_BYTES} bytes\n- Verification: {}", report.metadata.artifact.verification)
        .expect("writing to a String cannot fail");
    output.push_str("\nAll raw ranked values are available in `cases.jsonl`. This report is evidence collection, not shipping approval.\n");
    output
}

fn write_grouped_metrics(
    output: &mut String,
    title: &str,
    group_label: &str,
    groups: &BTreeMap<String, Metrics>,
) {
    writeln!(output, "\n## {title}\n").expect("writing to a String cannot fail");
    writeln!(output, "| {group_label} | Cases | Eligible | Useful | Eligible useful | Accepted precision | Exact-label precision | Useful coverage | Exact useful coverage | Abstention | Negative false conversions |")
        .expect("writing to a String cannot fail");
    output.push_str("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n");
    for (group, metrics) in groups {
        writeln!(
            output,
            "| {group} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |",
            metrics.total_cases,
            metrics.eligible_cases,
            metrics.useful_code_cases,
            metrics.eligible_useful_code_cases,
            format_rate(&metrics.accepted_precision),
            format_rate(&metrics.exact_label_precision_where_defined),
            format_rate(&metrics.useful_code_coverage),
            format_rate(&metrics.exact_useful_code_coverage),
            format_rate(&metrics.abstention),
            format_rate(&metrics.negative_false_conversions)
        )
        .expect("writing to a String cannot fail");
    }
}

fn write_metrics_table(output: &mut String, metrics: &Metrics) {
    output.push_str("| Metric | Raw | Rate |\n|---|---:|---:|\n");
    writeln!(output, "| Total cases | {} | n/a |", metrics.total_cases)
        .expect("writing to a String cannot fail");
    writeln!(
        output,
        "| Eligible cases | {} | n/a |",
        metrics.eligible_cases
    )
    .expect("writing to a String cannot fail");
    writeln!(
        output,
        "| Useful-code cases | {} | n/a |",
        metrics.useful_code_cases
    )
    .expect("writing to a String cannot fail");
    writeln!(
        output,
        "| Eligible useful-code cases | {} | n/a |",
        metrics.eligible_useful_code_cases
    )
    .expect("writing to a String cannot fail");
    writeln!(
        output,
        "| Accepted cases | {} | n/a |",
        metrics.accepted_cases
    )
    .expect("writing to a String cannot fail");
    writeln!(
        output,
        "| Accepted precision (accepted useful code / all accepted) | {}/{} | {} |",
        metrics.accepted_precision.numerator,
        metrics.accepted_precision.denominator,
        format_rate(&metrics.accepted_precision)
    )
    .expect("writing to a String cannot fail");
    writeln!(
        output,
        "| Exact-label precision where defined | {}/{} | {} |",
        metrics.exact_label_precision_where_defined.numerator,
        metrics.exact_label_precision_where_defined.denominator,
        format_rate(&metrics.exact_label_precision_where_defined)
    )
    .expect("writing to a String cannot fail");
    writeln!(
        output,
        "| Useful-code coverage | {}/{} | {} |",
        metrics.useful_code_coverage.numerator,
        metrics.useful_code_coverage.denominator,
        format_rate(&metrics.useful_code_coverage)
    )
    .expect("writing to a String cannot fail");
    writeln!(
        output,
        "| Exact useful-code coverage | {}/{} | {} |",
        metrics.exact_useful_code_coverage.numerator,
        metrics.exact_useful_code_coverage.denominator,
        format_rate(&metrics.exact_useful_code_coverage)
    )
    .expect("writing to a String cannot fail");
    writeln!(
        output,
        "| Abstention | {}/{} | {} |",
        metrics.abstention.numerator,
        metrics.abstention.denominator,
        format_rate(&metrics.abstention)
    )
    .expect("writing to a String cannot fail");
    writeln!(
        output,
        "| Negative false conversions | {}/{} | {} |",
        metrics.negative_false_conversions.numerator,
        metrics.negative_false_conversions.denominator,
        format_rate(&metrics.negative_false_conversions)
    )
    .expect("writing to a String cannot fail");
}

fn format_rate(rate: &Rate) -> String {
    match (rate.rate, &rate.wilson_95_percent) {
        (Some(value), Some(interval)) => format!(
            "{:.2}% (95% CI {:.2}–{:.2}%)",
            value * 100.0,
            interval.lower * 100.0,
            interval.upper * 100.0
        ),
        _ => "n/a".to_owned(),
    }
}

fn format_ns(value: Option<u64>) -> String {
    value.map_or_else(|| "unavailable".to_owned(), |value| format!("{value} ns"))
}

fn invalid(message: impl Into<String>) -> AnyError {
    io::Error::new(io::ErrorKind::InvalidData, message.into()).into()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn thresholds() -> Thresholds {
        Thresholds {
            minimum_non_whitespace_bytes: 3,
            minimum_top_score: 0.7,
            minimum_top_two_margin: 0.2,
            maximum_input_bytes: 5,
        }
    }

    fn ranked(top: f64, second: f64) -> Vec<RankedValue> {
        vec![
            RankedValue {
                score: top,
                slug: "rust".to_owned(),
            },
            RankedValue {
                score: second,
                slug: "python".to_owned(),
            },
        ]
    }

    fn result(
        surface: &str,
        expected: Option<&str>,
        useful_code: bool,
        eligible: bool,
        accepted: Option<&str>,
    ) -> CaseResult {
        CaseResult {
            id: "case".to_owned(),
            split: "tune".to_owned(),
            surface: surface.to_owned(),
            kind: if useful_code { "code" } else { "prose" }.to_owned(),
            expected: expected.map(str::to_owned),
            useful_code,
            input_bytes: 20,
            non_whitespace_bytes: 20,
            eligible,
            accepted: accepted.map(str::to_owned),
            abstention_reason: None,
            inference_nanoseconds: eligible.then_some(1),
            ranked: Vec::new(),
        }
    }

    #[test]
    fn threshold_edges_are_inclusive() {
        let config = thresholds();
        assert_eq!(eligibility_reason(b"a b c", 3, &config), None);
        assert_eq!(
            decide(&ranked(0.7, 0.5), &config).0.as_deref(),
            Some("rust")
        );
        assert_eq!(
            eligibility_reason(b"abcdef", 6, &config).as_deref(),
            Some("input_exceeds_maximum_bytes")
        );
        assert_eq!(decide(&ranked(0.699, 0.1), &config).0, None);
        assert_eq!(decide(&ranked(0.8, 0.601), &config).0, None);
    }

    #[test]
    fn family_expansion_is_deterministic_and_large() {
        let corpus = Corpus {
            schema_version: 2,
            cases: Vec::new(),
            families: vec![Family {
                id_prefix: "negative".to_owned(),
                split: Split::Holdout,
                generator: "paste_negative".to_owned(),
                count: 1_000,
                start_index: 600,
            }],
        };
        let expanded = expand_corpus(corpus).expect("family should expand");
        assert_eq!(expanded.len(), 1_000);
        assert_eq!(expanded[0].id, "negative-0000");
        assert_eq!(expanded[999].id, "negative-0999");
        assert!(String::from_utf8_lossy(&expanded[0].input).contains("Reminder 60"));
        assert!(expanded.iter().all(|case| !case.useful_code));
        assert!(expanded.iter().all(|case| case.surface == "paste"));
        let kinds = expanded
            .iter()
            .map(|case| case.kind.as_str())
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(kinds.len(), 10);
    }

    #[test]
    fn percentile_logic_uses_nearest_rank() {
        let mut samples = vec![50, 10, 40, 20, 30];
        let stats = latency_stats(&mut samples);
        assert_eq!(stats.p50_nanoseconds, Some(30));
        assert_eq!(stats.p95_nanoseconds, Some(50));
        assert_eq!(stats.max_nanoseconds, Some(50));
    }

    #[test]
    fn precision_and_coverage_use_correct_denominators() {
        let values = [
            result("paste", Some("rust"), true, true, Some("rust")),
            result("fence", Some("python"), true, true, Some("rust")),
            result("file", Some("go"), true, true, None),
            result("paste", Some("sql"), true, false, None),
            result("paste", None, false, true, Some("markdown")),
            result("paste", None, false, true, None),
        ];
        let references = values.iter().collect::<Vec<_>>();
        let metrics = calculate_metrics(&references);

        assert_eq!(metrics.useful_code_cases, 4);
        assert_eq!(metrics.eligible_useful_code_cases, 3);
        assert_eq!(metrics.accepted_precision.numerator, 2);
        assert_eq!(metrics.accepted_precision.denominator, 3);
        assert_eq!(metrics.exact_label_precision_where_defined.numerator, 1);
        assert_eq!(metrics.exact_label_precision_where_defined.denominator, 2);
        assert_eq!(metrics.useful_code_coverage.numerator, 2);
        assert_eq!(metrics.useful_code_coverage.denominator, 4);
        assert_eq!(metrics.exact_useful_code_coverage.numerator, 1);
        assert_eq!(metrics.exact_useful_code_coverage.denominator, 4);
        assert_eq!(metrics.negative_false_conversions.numerator, 1);
        assert_eq!(metrics.negative_false_conversions.denominator, 2);
        assert_eq!(
            Rate::new(0, 5).wilson_95_percent.expect("interval").lower,
            0.0
        );
        assert_eq!(
            Rate::new(5, 5).wilson_95_percent.expect("interval").upper,
            1.0
        );
    }

    #[test]
    fn metrics_group_by_product_surface_not_content_kind() {
        let values = [
            result("paste", Some("rust"), true, true, Some("rust")),
            result("paste", None, false, true, None),
            result("fence", Some("python"), true, true, Some("python")),
            result("file", Some("go"), true, true, None),
        ];
        let by_surface = metrics_by(&values, |result| result.surface.clone());

        assert_eq!(by_surface.len(), 3);
        assert_eq!(by_surface["paste"].total_cases, 2);
        assert_eq!(by_surface["paste"].accepted_precision.numerator, 1);
        assert_eq!(by_surface["paste"].accepted_precision.denominator, 1);
        assert_eq!(by_surface["fence"].total_cases, 1);
        assert_eq!(by_surface["file"].total_cases, 1);
    }

    #[test]
    fn negative_confusion_labels_retain_kind() {
        let negative = result("paste", None, false, true, Some("markdown"));
        assert_eq!(expected_confusion_label(&negative), "__negative__:prose");
    }
}
