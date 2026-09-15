//! Non-shipping synthetic evaluation harness for `betlang`.

use companion_language_detection_policy::{
    DetectionPolicy, EligibilityRejection, RankingRejection, count_non_whitespace,
    eligibility_rejection, ranking_rejection,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap};
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
    minimum_top_score: f32,
    minimum_top_two_margin: f32,
    maximum_input_bytes: usize,
}

impl Thresholds {
    fn policy(&self) -> DetectionPolicy {
        DetectionPolicy {
            minimum_non_whitespace_bytes: self.minimum_non_whitespace_bytes,
            minimum_top_score: self.minimum_top_score,
            minimum_top_two_margin: self.minimum_top_two_margin,
            maximum_input_bytes: self.maximum_input_bytes,
        }
    }

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
    score: f32,
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
    automatic_paste_conversions: u64,
    automatic_paste_precision: Rate,
    automatic_paste_useful_code_coverage: Rate,
    dedicated_paste_negative_conversions: Rate,
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
    top_score: Option<f32>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct Report {
    schema_version: u32,
    split: String,
    thresholds: Thresholds,
    metadata: RunMetadata,
    automatic_paste_gate: GateAssessment,
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

#[derive(Clone, Debug, Deserialize, Serialize)]
struct GateAssessment {
    status: String,
    requirements: Vec<String>,
    reasons: Vec<String>,
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
    let expanded = expand_corpus(corpus)?;
    validate_corpus(&expanded)?;
    let cases = expanded
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
        let eligibility = eligibility_reason(&case.input, &thresholds);
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
                score,
                slug: language.slug().to_owned(),
            })
        })
        .collect()
}

fn eligibility_reason(input: &[u8], thresholds: &Thresholds) -> Option<String> {
    eligibility_rejection(input, thresholds.policy()).map(|rejection| {
        match rejection {
            EligibilityRejection::InputExceedsMaximumBytes => "input_exceeds_maximum_bytes",
            EligibilityRejection::InputContainsNul => "input_contains_nul",
            EligibilityRejection::InputIsNotUtf8 => "input_is_not_utf8",
            EligibilityRejection::InsufficientNonWhitespaceBytes => {
                "insufficient_non_whitespace_bytes"
            }
        }
        .to_owned()
    })
}

fn decide(ranked: &[RankedValue], thresholds: &Thresholds) -> (Option<String>, Option<String>) {
    let rejection = ranking_rejection(ranked.iter().map(|value| value.score), thresholds.policy());
    if let Some(rejection) = rejection {
        let reason = match rejection {
            RankingRejection::FewerThanTwoRankings => "model_returned_fewer_than_two_rankings",
            RankingRejection::NonFiniteScore => "model_returned_non_finite_score",
            RankingRejection::TopScoreBelowMinimum => "top_score_below_minimum",
            RankingRejection::TopTwoMarginBelowMinimum => "top_two_margin_below_minimum",
        };
        return (None, Some(reason.to_owned()));
    }
    (ranked.first().map(|top| top.slug.clone()), None)
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

    let metrics = calculate_metrics(&results.iter().collect::<Vec<_>>());
    let automatic_paste_gate = assess_automatic_paste_gate(args.split, &metrics);

    Ok(Report {
        schema_version: 4,
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
        automatic_paste_gate,
        metrics,
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

fn assess_automatic_paste_gate(split: SplitFilter, metrics: &Metrics) -> GateAssessment {
    let requirements = vec![
        "at least 99% automatic-paste code precision on held-out conversions".to_owned(),
        "zero conversions over at least 1,000 dedicated prose/list/URL paste negatives".to_owned(),
        "report useful-code coverage and uncertainty".to_owned(),
        "at least one automatic paste conversion (all-abstain is forbidden)".to_owned(),
    ];
    if split != SplitFilter::Holdout {
        return GateAssessment {
            status: "insufficient_evidence".to_owned(),
            requirements,
            reasons: vec!["the gate can be concluded only from the holdout split".to_owned()],
        };
    }

    let mut insufficient = Vec::new();
    if metrics.dedicated_paste_negative_conversions.denominator < 1_000 {
        insufficient.push(format!(
            "only {} dedicated negatives; at least 1,000 required",
            metrics.dedicated_paste_negative_conversions.denominator
        ));
    }
    if metrics.automatic_paste_conversions == 0 {
        insufficient.push("no automatic paste conversions; all-abstain is forbidden".to_owned());
    }
    if !insufficient.is_empty() {
        return GateAssessment {
            status: "insufficient_evidence".to_owned(),
            requirements,
            reasons: insufficient,
        };
    }

    let mut failures = Vec::new();
    if metrics
        .automatic_paste_precision
        .rate
        .is_none_or(|rate| rate < 0.99)
    {
        failures.push(format!(
            "automatic-paste precision is {}/{}; at least 99% required",
            metrics.automatic_paste_precision.numerator,
            metrics.automatic_paste_precision.denominator
        ));
    }
    if metrics.dedicated_paste_negative_conversions.numerator != 0 {
        failures.push(format!(
            "{} dedicated negative conversions observed; zero required",
            metrics.dedicated_paste_negative_conversions.numerator
        ));
    }

    GateAssessment {
        status: if failures.is_empty() { "pass" } else { "fail" }.to_owned(),
        requirements,
        reasons: failures,
    }
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
    let paste_useful = results
        .iter()
        .filter(|result| result.surface == "paste" && result.useful_code)
        .count() as u64;
    let automatic_paste_conversions = results
        .iter()
        .filter(|result| is_automatic_paste_conversion(result))
        .count() as u64;
    let automatic_paste_useful = results
        .iter()
        .filter(|result| result.useful_code && is_automatic_paste_conversion(result))
        .count() as u64;
    let dedicated_paste_negatives = results
        .iter()
        .filter(|result| is_dedicated_paste_negative(result))
        .count() as u64;
    let dedicated_paste_negative_conversions = results
        .iter()
        .filter(|result| {
            is_dedicated_paste_negative(result) && is_automatic_paste_conversion(result)
        })
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
        automatic_paste_conversions,
        automatic_paste_precision: Rate::new(automatic_paste_useful, automatic_paste_conversions),
        automatic_paste_useful_code_coverage: Rate::new(automatic_paste_useful, paste_useful),
        dedicated_paste_negative_conversions: Rate::new(
            dedicated_paste_negative_conversions,
            dedicated_paste_negatives,
        ),
    }
}

fn is_automatic_paste_conversion(result: &CaseResult) -> bool {
    result.surface == "paste"
        && matches!(result.accepted.as_deref(), Some(slug) if slug != "markdown")
}

fn is_dedicated_paste_negative(result: &CaseResult) -> bool {
    result.surface == "paste"
        && !result.useful_code
        && matches!(result.kind.as_str(), "prose" | "list" | "url")
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
        for index in 0..family.count {
            let case = match family.generator.as_str() {
                "paste_negative" => generated_negative(&family, index),
                "dedicated_paste_negative" => generated_dedicated_paste_negative(&family, index),
                "independent_holdout_paste_negative" => {
                    generated_independent_holdout_paste_negative(&family, index)
                }
                "paste_code" => generated_paste_code(&family, index),
                "independent_holdout_paste_code" => {
                    generated_independent_holdout_paste_code(&family, index)
                }
                _ => {
                    return Err(invalid(format!(
                        "unknown family generator: {}",
                        family.generator
                    )));
                }
            };
            expanded.push(case);
        }
    }
    Ok(expanded)
}

fn validate_corpus(cases: &[EvalCase]) -> Result<(), AnyError> {
    let mut ids = BTreeSet::new();
    let mut inputs: HashMap<&[u8], (&str, Split)> = HashMap::new();
    for case in cases {
        if !ids.insert(case.id.as_str()) {
            return Err(invalid(format!("duplicate corpus case id: {}", case.id)));
        }
        if case.useful_code != case.expected.is_some() {
            return Err(invalid(format!(
                "case {} must define expected exactly when useful_code is true",
                case.id
            )));
        }
        if let Some((other_id, other_split)) = inputs.insert(&case.input, (&case.id, case.split)) {
            if other_split != case.split {
                return Err(invalid(format!(
                    "tune/holdout input overlap: {} and {}",
                    other_id, case.id
                )));
            }
            return Err(invalid(format!(
                "duplicate corpus input: {} and {}",
                other_id, case.id
            )));
        }
    }
    Ok(())
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

fn generated_dedicated_paste_negative(family: &Family, index: usize) -> EvalCase {
    let generation_index = family.start_index + index;
    let variant = generation_index % 3;
    let style = (generation_index / 3) % 8;
    let serial = generation_index / 24;
    let (kind, text) = match (variant, style) {
        (0, 0) => (
            "prose",
            format!(
                "Reminder {serial}: the east meeting room is reserved after lunch for the quarterly planning discussion."
            ),
        ),
        (0, 1) => (
            "prose",
            format!(
                "Note {serial}: please return the library books before walking to the neighborhood market."
            ),
        ),
        (0, 2) => (
            "prose",
            format!(
                "Update {serial}: the delivery will arrive tomorrow morning, and reception has the tracking details."
            ),
        ),
        (0, 3) => (
            "prose",
            format!(
                "Message {serial}: we reviewed the draft together and agreed to discuss the remaining questions next week."
            ),
        ),
        (0, 4) => (
            "prose",
            format!(
                "Agenda item {serial}: compare the travel options, choose a departure time, and notify the group."
            ),
        ),
        (0, 5) => (
            "prose",
            format!(
                "Journal entry {serial}: rain continued through the afternoon while the garden paths slowly filled with water."
            ),
        ),
        (0, 6) => (
            "prose",
            format!(
                "Notice {serial}: visitors should sign in at the front desk and wear a badge inside the building."
            ),
        ),
        (0, _) => (
            "prose",
            format!(
                "Summary {serial}: customer interviews identified clearer instructions as the most common request."
            ),
        ),
        (1, 0) => (
            "list",
            format!("Groceries {serial}:\n- apples\n- rice\n- coffee\n- soap"),
        ),
        (1, 1) => (
            "list",
            format!(
                "Weekend tasks {serial}\n1. Water the plants\n2. Wash the towels\n3. Call the family"
            ),
        ),
        (1, 2) => (
            "list",
            format!("Packing checklist {serial}:\n• passport\n• charger\n• notebook\n• raincoat"),
        ),
        (1, 3) => (
            "list",
            format!(
                "Meeting topics {serial}:\n- budget review\n- hiring update\n- office schedule"
            ),
        ),
        (1, 4) => (
            "list",
            format!("Books to borrow {serial}\n1) Local history\n2) Winter gardens\n3) City maps"),
        ),
        (1, 5) => (
            "list",
            format!("Supplies for room {serial}: paper, markers, tape, folders, and name cards."),
        ),
        (1, 6) => (
            "list",
            format!("Travel plan {serial}\nMorning — train\nAfternoon — museum\nEvening — dinner"),
        ),
        (1, _) => (
            "list",
            format!(
                "Priorities {serial}:\nA. Confirm attendance\nB. Reserve tables\nC. Send directions"
            ),
        ),
        (2, 0) => (
            "url",
            format!("https://example.invalid/articles/{serial}/planning-a-meeting"),
        ),
        (2, 1) => (
            "url",
            format!("https://docs.example.invalid/guide/{serial}?view=reader&lang=en"),
        ),
        (2, 2) => (
            "url",
            format!("https://calendar.example.invalid/events/{serial}#schedule"),
        ),
        (2, 3) => (
            "url",
            format!("https://shop.example.invalid/products/notebook-{serial}/reviews"),
        ),
        (2, 4) => (
            "url",
            format!("https://maps.example.invalid/place/library-{serial}?zoom=14"),
        ),
        (2, 5) => (
            "url",
            format!("https://news.example.invalid/2026/09/story-{serial}.html"),
        ),
        (2, 6) => (
            "url",
            format!("https://support.example.invalid/tickets/{serial}?status=open"),
        ),
        (2, _) => (
            "url",
            format!("https://community.example.invalid/topics/{serial}-welcome-to-the-group"),
        ),
        _ => unreachable!(),
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

fn generated_independent_holdout_paste_negative(family: &Family, index: usize) -> EvalCase {
    const SUBJECTS: [&str; 10] = [
        "the design group",
        "our neighbor",
        "the evening class",
        "a museum guide",
        "the clinic receptionist",
        "the volunteer team",
        "the train conductor",
        "the building manager",
        "the local baker",
        "the school librarian",
    ];
    const ACTIVITIES: [&str; 10] = [
        "confirmed the revised schedule",
        "moved the appointment",
        "found the missing parcel",
        "prepared the visitor badges",
        "reserved a quieter room",
        "returned the borrowed equipment",
        "reviewed the printed map",
        "cancelled the afternoon delivery",
        "shared the meeting summary",
        "reported a broken window",
    ];
    const TIMES: [&str; 4] = [
        "before breakfast",
        "shortly after noon",
        "during the evening",
        "early next week",
    ];
    const LIST_TITLES: [&str; 10] = [
        "Items beside the door",
        "Things to discuss",
        "Stops on the walk",
        "Names for the table",
        "Food for the picnic",
        "Rooms to inspect",
        "Calls to return",
        "Gifts to wrap",
        "Plants to water",
        "Documents to bring",
    ];
    const LIST_ITEMS: [[&str; 3]; 10] = [
        ["blue umbrella", "canvas bag", "spare keys"],
        ["arrival time", "seating plan", "dietary notes"],
        ["post office", "public garden", "corner shop"],
        ["Mara", "Tomas", "Yuki"],
        ["bread rolls", "pears", "sparkling water"],
        ["front office", "west stairwell", "storage room"],
        ["dentist", "electrician", "music teacher"],
        ["striped scarf", "wooden puzzle", "recipe book"],
        ["fern", "rosemary", "small lemon tree"],
        ["train ticket", "museum pass", "hotel address"],
    ];
    const URL_HOSTS: [&str; 10] = [
        "library.example.invalid",
        "events.example.invalid",
        "travel.example.invalid",
        "recipes.example.invalid",
        "gallery.example.invalid",
        "weather.example.invalid",
        "transit.example.invalid",
        "catalog.example.invalid",
        "school.example.invalid",
        "garden.example.invalid",
    ];
    const URL_PATHS: [&str; 10] = [
        "reading-rooms",
        "autumn-calendar",
        "coastal-routes",
        "soup-collection",
        "new-exhibitions",
        "weekly-outlook",
        "station-access",
        "linen-notebooks",
        "family-evening",
        "winter-pruning",
    ];
    const URL_SUFFIXES: [&str; 4] = [
        "?display=compact",
        "?language=en#details",
        "/printable",
        "?from=newsletter&mode=reader",
    ];

    let generation_index = family.start_index + index;
    let variant = generation_index % 3;
    let combination = generation_index / 3;
    let first = combination % 10;
    let second = (combination / 10) % 10;
    let style = (combination / 100) % 4;
    let (kind, text) = match variant {
        0 => {
            let text = match style {
                0 => format!(
                    "{} {} {}.",
                    SUBJECTS[first], ACTIVITIES[second], TIMES[style]
                ),
                1 => format!(
                    "{}: {} said that {}.",
                    TIMES[style], SUBJECTS[first], ACTIVITIES[second]
                ),
                2 => format!(
                    "A handwritten note explains that {} {} {}.",
                    SUBJECTS[first], ACTIVITIES[second], TIMES[style]
                ),
                _ => format!(
                    "Please remember: {} {}, {}.",
                    SUBJECTS[first], ACTIVITIES[second], TIMES[style]
                ),
            };
            ("prose", text)
        }
        1 => {
            let items = LIST_ITEMS[second];
            let text = match style {
                0 => format!(
                    "{}\n• {}\n• {}\n• {}",
                    LIST_TITLES[first], items[0], items[1], items[2]
                ),
                1 => format!(
                    "{}:\n(a) {}\n(b) {}\n(c) {}",
                    LIST_TITLES[first], items[0], items[1], items[2]
                ),
                2 => format!(
                    "{} — {}, {}, and {}.",
                    LIST_TITLES[first], items[0], items[1], items[2]
                ),
                _ => format!(
                    "{}\n□ {}\n□ {}\n□ {}",
                    LIST_TITLES[first], items[0], items[1], items[2]
                ),
            };
            ("list", text)
        }
        _ => (
            "url",
            format!(
                "https://{}/{}/{}{}",
                URL_HOSTS[first],
                URL_PATHS[second],
                first + second + 1,
                URL_SUFFIXES[style]
            ),
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

fn generated_paste_code(family: &Family, index: usize) -> EvalCase {
    let generation_index = family.start_index + index;
    let variant = generation_index % 12;
    let serial = generation_index / 12;
    let (expected, text) = match variant {
        0 => (
            "rust",
            format!(
                "fn total_{serial}(values: &[i32]) -> i32 {{ values.iter().copied().filter(|value| *value > 0).sum() }}\nprintln!(\"{{}}\", total_{serial}(&[1, -2, 3]));"
            ),
        ),
        1 => (
            "python",
            format!(
                "def total_{serial}(values):\n    return sum(value for value in values if value > 0)\n\nprint(total_{serial}([1, -2, 3]))"
            ),
        ),
        2 => (
            "javascript",
            format!(
                "const enabled{serial} = users.filter((user) => user.enabled);\nconsole.log(enabled{serial}.map((user) => user.id));"
            ),
        ),
        3 => (
            "typescript",
            format!(
                "interface Record{serial} {{ id: number; active: boolean }}\nconst active{serial}: Record{serial}[] = records.filter((item) => item.active);"
            ),
        ),
        4 => (
            "swift",
            format!(
                "struct Greeter{serial} {{ let name: String; func message() -> String {{ \"Hello, \\(name)!\" }} }}\nprint(Greeter{serial}(name: \"World\").message())"
            ),
        ),
        5 => (
            "go",
            format!(
                "package main\nimport \"fmt\"\nfunc total{serial}(values []int) int {{ sum := 0; for _, value := range values {{ sum += value }}; return sum }}\nfunc main() {{ fmt.Println(total{serial}([]int{{1, 2, 3}})) }}"
            ),
        ),
        6 => (
            "shell",
            format!(
                "#!/bin/sh\nset -eu\nfor file in sample-{serial}/*.txt; do\n  printf '%s\\n' \"$file\"\ndone"
            ),
        ),
        7 => (
            "sql",
            format!(
                "SELECT account_id, COUNT(*) AS event_count_{serial}\nFROM audit_events\nWHERE created_at >= CURRENT_DATE\nGROUP BY account_id\nORDER BY event_count_{serial} DESC;"
            ),
        ),
        8 => (
            "json",
            format!(
                "{{\"batch\": {serial}, \"enabled\": true, \"items\": [{{\"id\": 1}}, {{\"id\": 2}}], \"owner\": null}}"
            ),
        ),
        9 => (
            "yaml",
            format!(
                "job_{serial}:\n  enabled: true\n  retries: 3\n  tags:\n    - synthetic\n    - evaluation"
            ),
        ),
        10 => (
            "toml",
            format!(
                "[job_{serial}]\nenabled = true\nretries = 3\ntags = [\"synthetic\", \"evaluation\"]"
            ),
        ),
        _ => (
            "ruby",
            format!(
                "def total_{serial}(values)\n  values.select {{ |value| value.positive? }}.sum\nend\n\nputs total_{serial}([1, -2, 3])"
            ),
        ),
    };
    EvalCase {
        id: format!("{}-{index:04}", family.id_prefix),
        split: family.split,
        surface: "paste".to_owned(),
        kind: "code".to_owned(),
        expected: Some(expected.to_owned()),
        useful_code: true,
        input: text.into_bytes(),
    }
}

fn generated_independent_holdout_paste_code(family: &Family, index: usize) -> EvalCase {
    let generation_index = family.start_index + index;
    let variant = generation_index % 12;
    let name = [
        "amber", "birch", "cedar", "dune", "elm", "fjord", "grove", "harbor", "iris", "juniper",
    ][(generation_index / 12) % 10];
    let (expected, text) = match variant {
        0 => (
            "rust",
            format!(
                "enum Signal {{ Ready, Waiting }}\nfn describe_{name}(value: Signal) -> &'static str {{ match value {{ Signal::Ready => \"ready\", Signal::Waiting => \"waiting\" }} }}"
            ),
        ),
        1 => (
            "python",
            format!(
                "from pathlib import Path\n\ndef names_{name}(root):\n    return sorted(path.stem for path in Path(root).glob(\"*.txt\"))\n\nprint(names_{name}(\"notes\"))"
            ),
        ),
        2 => (
            "javascript",
            format!(
                "async function load{name}(url) {{\n  const response = await fetch(url);\n  if (!response.ok) throw new Error(response.statusText);\n  return response.json();\n}}"
            ),
        ),
        3 => (
            "typescript",
            format!(
                "type Entry{name} = {{ label: string; count: number }};\nfunction labels{name}(entries: Entry{name}[]): string[] {{\n  return entries.filter((entry) => entry.count > 0).map((entry) => entry.label);\n}}"
            ),
        ),
        4 => (
            "swift",
            format!(
                "enum Route{name}: String, CaseIterable {{ case home, archive, settings }}\nlet labels{name} = Route{name}.allCases.map(\\.rawValue)\nprint(labels{name}.joined(separator: \", \"))"
            ),
        ),
        5 => (
            "go",
            format!(
                "package main\nimport (\"fmt\"; \"strings\")\nfunc main() {{ words{name} := []string{{\"north\", \"south\"}}; fmt.Println(strings.Join(words{name}, \",\")) }}"
            ),
        ),
        6 => (
            "shell",
            format!(
                "#!/bin/sh\nset -eu\ndestination='{name}-archive'\nmkdir -p \"$destination\"\nfind notes -type f -name '*.md' -exec cp {{}} \"$destination\" \\;"
            ),
        ),
        7 => (
            "sql",
            format!(
                "WITH recent_{name} AS (\n  SELECT customer_id, MAX(created_at) AS latest\n  FROM orders GROUP BY customer_id\n)\nSELECT customer_id, latest FROM recent_{name} WHERE latest IS NOT NULL;"
            ),
        ),
        8 => (
            "json",
            format!(
                "{{\"workspace\":\"{name}\",\"members\":[{{\"name\":\"Ada\",\"active\":true}},{{\"name\":\"Lin\",\"active\":false}}],\"limit\":12}}"
            ),
        ),
        9 => (
            "yaml",
            format!(
                "service_{name}:\n  image: example.invalid/worker:1\n  environment:\n    MODE: batch\n    RETRIES: '4'\n  ports:\n    - '8080:8080'"
            ),
        ),
        10 => (
            "toml",
            format!(
                "[workspace.{name}]\nroot = \"./documents\"\nexclude = [\"drafts\", \"tmp\"]\n\n[workspace.{name}.display]\nline_numbers = true"
            ),
        ),
        _ => (
            "ruby",
            format!(
                "class Ledger{name}\n  def initialize\n    @entries = Hash.new(0)\n  end\n  def add(label)\n    @entries[label] += 1\n  end\nend"
            ),
        ),
    };
    EvalCase {
        id: format!("{}-{index:04}", family.id_prefix),
        split: family.split,
        surface: "paste".to_owned(),
        kind: "code".to_owned(),
        expected: Some(expected.to_owned()),
        useful_code: true,
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

    output.push_str("\n## Automatic-paste gate\n\n");
    writeln!(
        output,
        "- Conclusion: **{}**",
        report.automatic_paste_gate.status
    )
    .expect("writing to a String cannot fail");
    for reason in &report.automatic_paste_gate.reasons {
        writeln!(output, "- {reason}").expect("writing to a String cannot fail");
    }

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
    writeln!(
        output,
        "| Automatic paste conversions | {} | n/a |",
        metrics.automatic_paste_conversions
    )
    .expect("writing to a String cannot fail");
    writeln!(
        output,
        "| Automatic paste precision | {}/{} | {} |",
        metrics.automatic_paste_precision.numerator,
        metrics.automatic_paste_precision.denominator,
        format_rate(&metrics.automatic_paste_precision)
    )
    .expect("writing to a String cannot fail");
    writeln!(
        output,
        "| Automatic paste useful-code coverage | {}/{} | {} |",
        metrics.automatic_paste_useful_code_coverage.numerator,
        metrics.automatic_paste_useful_code_coverage.denominator,
        format_rate(&metrics.automatic_paste_useful_code_coverage)
    )
    .expect("writing to a String cannot fail");
    writeln!(
        output,
        "| Dedicated prose/list/URL paste-negative conversions | {}/{} | {} |",
        metrics.dedicated_paste_negative_conversions.numerator,
        metrics.dedicated_paste_negative_conversions.denominator,
        format_rate(&metrics.dedicated_paste_negative_conversions)
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

    fn ranked(top: f32, second: f32) -> Vec<RankedValue> {
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

    fn evaluate_with_policy(input: &[u8], policy: DetectionPolicy) -> Option<String> {
        if eligibility_rejection(input, policy).is_some() {
            return None;
        }
        let detection = betlang::detect(input);
        let ranked = collect_ranked(&detection).expect("fixture rankings must be finite");
        let thresholds = Thresholds {
            minimum_non_whitespace_bytes: policy.minimum_non_whitespace_bytes,
            minimum_top_score: policy.minimum_top_score,
            minimum_top_two_margin: policy.minimum_top_two_margin,
            maximum_input_bytes: policy.maximum_input_bytes,
        };
        decide(&ranked, &thresholds).0
    }

    #[test]
    fn evaluator_matches_the_production_adapter_across_eligibility_and_paste_policy() {
        let policy = companion_language_detection_policy::PRODUCTION_POLICY;
        let oversized = vec![b'x'; policy.maximum_input_bytes + 1];
        let fixtures: [&[u8]; 7] = [
            b"def total(values):\n    return sum(values)\nprint(total([1, 2, 3]))",
            b"# Meeting notes\n\n- confirm attendance\n- reserve a room\n- send directions",
            b"fn x() {}",
            b"fn main() {\0 println!(\"no\"); }",
            &[0xff; 20],
            b"                    ",
            &oversized,
        ];

        for input in fixtures {
            let production = companion_core::detect_source_language(input).map(str::to_owned);
            let evaluator = evaluate_with_policy(input, policy);
            assert_eq!(evaluator, production, "adapter drift for {input:?}");

            let production_paste = production.filter(|slug| slug != "markdown");
            let evaluator_paste = evaluator.filter(|slug| slug != "markdown");
            assert_eq!(evaluator_paste, production_paste, "paste-policy drift");
        }
    }

    #[test]
    fn production_policy_matches_the_committed_external_baseline_shape() {
        let baseline: Thresholds = serde_json::from_str(include_str!("../data/zed-baseline.json"))
            .expect("baseline must parse");
        assert_eq!(
            baseline.policy(),
            companion_language_detection_policy::PRODUCTION_POLICY
        );
    }

    #[test]
    fn threshold_edges_are_inclusive() {
        let config = thresholds();
        assert_eq!(eligibility_reason(b"a b c", &config), None);
        assert_eq!(
            decide(&ranked(0.7, 0.5), &config).0.as_deref(),
            Some("rust")
        );
        assert_eq!(
            eligibility_reason(b"abcdef", &config).as_deref(),
            Some("input_exceeds_maximum_bytes")
        );
        assert_eq!(decide(&ranked(0.699, 0.1), &config).0, None);
        assert_eq!(decide(&ranked(0.8, 0.601), &config).0, None);
        assert_eq!(
            eligibility_reason(b"abc\0d", &config).as_deref(),
            Some("input_contains_nul")
        );
        assert_eq!(
            eligibility_reason(&[0xff, 0xfe, b'a'], &config).as_deref(),
            Some("input_is_not_utf8")
        );
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
    fn generated_family_implementations_are_split_specific() {
        let corpus: Corpus =
            serde_json::from_str(include_str!("../data/corpus.json")).expect("corpus must parse");
        let tune = corpus
            .families
            .iter()
            .filter(|family| family.split == Split::Tune)
            .map(|family| family.generator.as_str())
            .collect::<BTreeSet<_>>();
        let holdout = corpus
            .families
            .iter()
            .filter(|family| family.split == Split::Holdout)
            .map(|family| family.generator.as_str())
            .collect::<BTreeSet<_>>();
        assert!(tune.is_disjoint(&holdout));
    }

    #[test]
    fn independent_holdout_negative_family_is_unique_and_gate_scoped() {
        let family = Family {
            id_prefix: "holdout-negative".to_owned(),
            split: Split::Holdout,
            generator: "independent_holdout_paste_negative".to_owned(),
            count: 1_200,
            start_index: 600,
        };
        let cases = (0..family.count)
            .map(|index| generated_independent_holdout_paste_negative(&family, index))
            .collect::<Vec<_>>();
        let inputs = cases
            .iter()
            .map(|case| case.input.as_slice())
            .collect::<BTreeSet<_>>();

        assert_eq!(inputs.len(), 1_200);
        assert!(cases.iter().all(is_dedicated_paste_negative_case));
    }

    #[test]
    fn dedicated_negative_family_contains_only_gate_kinds() {
        let family = Family {
            id_prefix: "negative".to_owned(),
            split: Split::Holdout,
            generator: "dedicated_paste_negative".to_owned(),
            count: 1_200,
            start_index: 600,
        };
        let cases = (0..family.count)
            .map(|index| generated_dedicated_paste_negative(&family, index))
            .collect::<Vec<_>>();

        assert_eq!(cases.len(), 1_200);
        assert!(cases.iter().all(is_dedicated_paste_negative_case));
    }

    fn is_dedicated_paste_negative_case(case: &EvalCase) -> bool {
        case.surface == "paste"
            && !case.useful_code
            && matches!(case.kind.as_str(), "prose" | "list" | "url")
    }

    #[test]
    fn corpus_validation_rejects_split_overlap() {
        let input = b"same input".to_vec();
        let cases = vec![
            EvalCase {
                id: "tune".to_owned(),
                split: Split::Tune,
                surface: "paste".to_owned(),
                kind: "prose".to_owned(),
                expected: None,
                useful_code: false,
                input: input.clone(),
            },
            EvalCase {
                id: "holdout".to_owned(),
                split: Split::Holdout,
                surface: "paste".to_owned(),
                kind: "prose".to_owned(),
                expected: None,
                useful_code: false,
                input,
            },
        ];

        assert!(
            validate_corpus(&cases)
                .expect_err("overlap must fail")
                .to_string()
                .contains("tune/holdout input overlap")
        );
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
        assert_eq!(metrics.automatic_paste_conversions, 1);
        assert_eq!(metrics.automatic_paste_precision.numerator, 1);
        assert_eq!(metrics.automatic_paste_precision.denominator, 1);
        assert_eq!(metrics.automatic_paste_useful_code_coverage.numerator, 1);
        assert_eq!(metrics.automatic_paste_useful_code_coverage.denominator, 2);
        assert_eq!(metrics.dedicated_paste_negative_conversions.numerator, 0);
        assert_eq!(metrics.dedicated_paste_negative_conversions.denominator, 2);
        assert_eq!(
            assess_automatic_paste_gate(SplitFilter::Holdout, &metrics).status,
            "insufficient_evidence"
        );
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
    fn holdout_gate_reports_pass_and_fail() {
        let mut passing = Metrics {
            automatic_paste_conversions: 100,
            automatic_paste_precision: Rate::new(99, 100),
            dedicated_paste_negative_conversions: Rate::new(0, 1_000),
            ..Metrics::default()
        };
        assert_eq!(
            assess_automatic_paste_gate(SplitFilter::Holdout, &passing).status,
            "pass"
        );

        passing.dedicated_paste_negative_conversions = Rate::new(1, 1_000);
        assert_eq!(
            assess_automatic_paste_gate(SplitFilter::Holdout, &passing).status,
            "fail"
        );
        assert_eq!(
            assess_automatic_paste_gate(SplitFilter::Tune, &passing).status,
            "insufficient_evidence"
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
