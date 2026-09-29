//! CamiTune's offline JSON boundary for the pinned AutoEQ speaker optimizer.
use autoeq_optim::optim::compute_base_fitness;
use autoeq_optim::optim::setup::{perform_optimization, setup_objective_data};
use autoeq_optim::{Curve, LossType, OptimParams, PeqModel};
use base64::{Engine, engine::general_purpose::STANDARD};
use ndarray::Array1;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    io::{self, Read},
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    schema_version: u32,
    mode: String,
    speaker_name: String,
    measurement_version: String,
    measurement_type: String,
    sample_rate: f64,
    filter_count: usize,
    min_frequency: f64,
    max_frequency: f64,
    #[serde(rename = "minimumGainDB")]
    minimum_gain_db: f64,
    #[serde(rename = "maximumGainDB")]
    maximum_gain_db: f64,
    minimum_q: f64,
    maximum_q: f64,
    // Keep exact source bytes; hashes never depend on JSON reserialization.
    #[serde(rename = "rawCEA2034")]
    raw_cea2034: String,
}
fn numbers(value: &Value) -> Result<Vec<f64>, String> {
    let values = if let Some(array) = value.as_array() {
        array
            .iter()
            .map(|v| v.as_f64().ok_or("Non-numeric curve point".into()))
            .collect::<Result<Vec<_>, String>>()?
    } else {
        let dtype = value["dtype"].as_str().ok_or("Missing numeric dtype")?;
        let bytes = STANDARD
            .decode(value["bdata"].as_str().ok_or("Missing numeric payload")?)
            .map_err(|e| e.to_string())?;
        let width = match dtype {
            "f8" => 8,
            "f4" => 4,
            _ => return Err("Unsupported numeric dtype".into()),
        };
        if bytes.len() % width != 0 {
            return Err("Truncated numeric payload".into());
        }
        bytes
            .chunks_exact(width)
            .map(|v| {
                if width == 8 {
                    f64::from_le_bytes(v.try_into().unwrap())
                } else {
                    f32::from_le_bytes(v.try_into().unwrap()) as f64
                }
            })
            .collect()
    };
    if values.len() < 16 || values.iter().any(|v| !v.is_finite()) {
        return Err("Invalid curve values".into());
    }
    Ok(values)
}
fn parse_curves(raw: &str) -> Result<HashMap<String, Curve>, String> {
    let mut value: Value = serde_json::from_str(raw).map_err(|e| e.to_string())?;
    if let Some(array) = value.as_array() {
        value = serde_json::from_str(
            array
                .first()
                .and_then(Value::as_str)
                .ok_or("Malformed API envelope")?,
        )
        .map_err(|e| e.to_string())?;
    } else if let Some(s) = value.as_str() {
        value = serde_json::from_str(s).map_err(|e| e.to_string())?;
    }
    let mut curves = HashMap::new();
    for trace in value["data"].as_array().ok_or("Missing CEA2034 traces")? {
        let name = trace["name"].as_str().unwrap_or("");
        if ![
            "On Axis",
            "Listening Window",
            "Early Reflections",
            "Sound Power",
            "Estimated In-Room Response",
            "Early Reflections DI",
            "Sound Power DI",
        ]
        .contains(&name)
        {
            continue;
        }
        let freq = numbers(&trace["x"])?;
        let spl = numbers(&trace["y"])?;
        if freq.len() != spl.len()
            || freq.iter().any(|f| *f <= 0.)
            || freq.windows(2).any(|w| w[0] >= w[1])
        {
            return Err("Invalid frequency grid".into());
        }
        if curves
            .insert(
                name.to_owned(),
                Curve {
                    freq: Array1::from_vec(freq),
                    spl: Array1::from_vec(spl),
                    ..Default::default()
                },
            )
            .is_some()
        {
            return Err("Duplicate CEA2034 trace".into());
        }
    }
    autoeq_optim::cea2034::SpinoramaBundleBuilder::new()
        .curves(curves)
        .build()
        .map(|bundle| bundle.curves)
        .map_err(|e| e.to_string())
}
fn run(r: Request) -> Result<Value, String> {
    let vals = [
        r.sample_rate,
        r.min_frequency,
        r.max_frequency,
        r.minimum_gain_db,
        r.maximum_gain_db,
        r.minimum_q,
        r.maximum_q,
    ];
    if r.schema_version != 1
        || r.measurement_type != "CEA2034"
        || r.speaker_name.is_empty()
        || r.measurement_version.is_empty()
        || vals.iter().any(|x| !x.is_finite())
        || !(1..=12).contains(&r.filter_count)
        || !(32000.0..=192000.0).contains(&r.sample_rate)
        || r.min_frequency < 40.
        || r.max_frequency > 20000.
        || r.min_frequency >= r.max_frequency
        || r.max_frequency >= r.sample_rate / 2.
        || r.minimum_gain_db < -24.
        || r.minimum_gain_db >= 0.
        || r.maximum_gain_db < 0.
        || r.maximum_gain_db > 6.
        || r.minimum_q < 0.5
        || r.maximum_q > 6.
        || r.minimum_q > r.maximum_q
    {
        return Err("Invalid speaker optimization bounds".into());
    }
    let mut p = OptimParams::from(&autoeq_optim::cli::Args::speaker_defaults());
    p.loss = match r.mode.as_str() {
        "nearField" => LossType::SpeakerFlat,
        "farField" => LossType::SpeakerScore,
        _ => return Err("Unknown listening mode".into()),
    };
    p.num_filters = r.filter_count;
    p.peq_model = PeqModel::Pk;
    p.sample_rate = r.sample_rate;
    p.min_freq = r.min_frequency;
    p.max_freq = r.max_frequency;
    p.min_db = r.minimum_gain_db;
    p.max_db = r.maximum_gain_db;
    p.min_q = r.minimum_q;
    p.max_q = r.maximum_q;
    p.algo = "autoeq:de".into();
    p.refine = true;
    p.local_algo = "autoeq:cobyla".into();
    p.seed = Some(0xCA117E);
    p.no_parallel = true;
    p.quiet = true;
    let source = parse_curves(&r.raw_cea2034)?;
    let lw = source
        .get("Listening Window")
        .ok_or("CEA2034 Listening Window is missing")?;
    // Match the upstream speaker workflow: one common logarithmic grid and
    // upstream normalization/interpolation of each CEA2034 trace.
    let freq = autoeq_optim::read::create_log_frequency_grid(300, p.min_freq, p.max_freq);
    for name in [
        "On Axis",
        "Listening Window",
        "Sound Power",
        "Estimated In-Room Response",
    ] {
        let c = source
            .get(name)
            .ok_or(format!("CEA2034 {name} is missing"))?;
        if c.freq[0] > p.min_freq || c.freq[c.freq.len() - 1] < p.max_freq {
            return Err(format!(
                "CEA2034 {name} does not cover the correction range"
            ));
        }
    }
    let input = autoeq_optim::read::normalize_and_interpolate_response(&freq, lw);
    let spin = source
        .iter()
        .map(|(name, c)| {
            (
                name.clone(),
                autoeq_optim::read::normalize_and_interpolate_response(&freq, c),
            )
        })
        .collect();
    let target = Curve {
        freq: freq.clone(),
        spl: Array1::zeros(freq.len()),
        ..Default::default()
    };
    let deviation = Curve {
        freq: freq.clone(),
        spl: &target.spl - &input.spl,
        ..Default::default()
    };
    let (objective, _) = setup_objective_data(&p, &input, &target, &deviation, &Some(spin))
        .map_err(|e| e.to_string())?;
    let mut neutral = Vec::new();
    for i in 0..p.num_filters {
        neutral.extend([
            p.min_freq.log10()
                + (p.max_freq / p.min_freq).log10() * (i as f64 + 0.5) / p.num_filters as f64,
            p.min_q,
            0.,
        ]);
    }
    let before = compute_base_fitness(&neutral, &objective);
    let x = perform_optimization(&p, &objective).map_err(|e| e.to_string())?;
    let after = compute_base_fitness(&x, &objective);
    if !after.is_finite() || after > before + 1e-6 {
        return Err("Optimization did not improve the speaker objective".into());
    }
    let filters:Vec<Value>=x.chunks_exact(3).map(|v| {
        let frequency=10f64.powf(v[0]);
        // Log-frequency conversion can round 16 kHz to 16000.00000000001.
        // Canonicalize only numerical boundary noise; never hide unsafe results.
        if frequency < p.min_freq-1e-8 || frequency > p.max_freq+1e-8
            || v[1]<p.min_q-1e-10 || v[1]>p.max_q+1e-10
            || v[2]<p.min_db-1e-10 || v[2]>p.max_db+1e-10 {
            return Err("Optimizer exceeded the configured filter bounds".to_string());
        }
        Ok(json!({"type":"PK","frequency":frequency.clamp(p.min_freq,p.max_freq),"q":v[1].clamp(p.min_q,p.max_q),"gainDB":v[2].clamp(p.min_db,p.max_db)}))
    }).collect::<Result<_,String>>()?;
    let hash = format!("{:x}", Sha256::digest(r.raw_cea2034.as_bytes()));
    Ok(
        json!({"schemaVersion":1,"filters":filters,"sourceHash":hash,
        "engine":{"name":"autoeq","version":"0.5.62@06ec8f958f11","mode":if r.mode=="nearField"{"speaker-flat"}else{"speaker-score"}},
        "diagnostics":{"converged":true,"warnings":[],"objectiveBefore":before,"objectiveAfter":after}}),
    )
}
fn main() {
    let mut input = String::new();
    let result = io::stdin()
        .take(8 * 1024 * 1024 + 1)
        .read_to_string(&mut input)
        .map_err(|e| e.to_string())
        .and_then(|_| {
            if input.len() > 8 * 1024 * 1024 {
                return Err("Request exceeds limit".into());
            }
            let r = serde_json::from_str(&input).map_err(|e| e.to_string())?;
            run(r)
        });
    match result {
        Ok(v) => println!("{v}"),
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}

// Optional tests live in the ignored local Tests directory.
#[cfg(all(test, feature = "local-tests"))]
#[path = "../../../Tests/DeviceCorrectionRegression/SpeakerEQCoreTests.rs"]
mod tests;
