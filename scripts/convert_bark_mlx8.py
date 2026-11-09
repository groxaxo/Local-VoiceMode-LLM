#!/usr/bin/env python3
"""Convert Bark Pro's HF BF16 tensors to MLX, then apply 8-bit affine quantization."""
import hashlib, json, pathlib, re, shutil
import mlx.core as mx
from mlx.utils import tree_flatten
from mlx_audio.stt.models.parakeet import Model, ModelConfig
from mlx_audio.convert import convert
from mlx_audio.stt import load
RENAMES = [
    (r"encoder\.subsampling\.layers\.", "encoder.pre_encode.conv."),
    (r"encoder\.subsampling\.linear\.", "encoder.pre_encode.out."),
    (r"\.conv\.norm\.", ".conv.batch_norm."),
    (r"\.q_proj\.", ".linear_q."), (r"\.k_proj\.", ".linear_k."),
    (r"\.v_proj\.", ".linear_v."), (r"\.o_proj\.", ".linear_out."),
    (r"\.relative_k_proj\.", ".linear_pos."),
    (r"\.bias_u$", ".pos_bias_u"), (r"\.bias_v$", ".pos_bias_v"),
    (r"^decoder\.embedding\.", "decoder.prediction.embed."),
    (r"^encoder_projector\.", "joint.enc."),
    (r"^decoder\.decoder_projector\.", "joint.pred."),
    (r"^joint\.head\.", "joint.joint_net.2."),
]
def map_weights(source):
    out, skipped, lstm_bias = {}, [], {}
    for name, value in source.items():
        if name.endswith("num_batches_tracked"):
            skipped.append(name)
            continue
        match = re.fullmatch(r"decoder\.lstm\.(weight_ih|weight_hh|bias_ih|bias_hh)_l(\d+)", name)
        if match:
            kind, index = match.groups()
            prefix = f"decoder.prediction.dec_rnn.lstm.{index}"
            if kind.startswith("bias_"):
                key = prefix + ".bias"
                lstm_bias.setdefault(key, []).append(value.astype(mx.float32))
            else:
                out[prefix + (".Wx" if kind == "weight_ih" else ".Wh")] = value
            continue
        if re.fullmatch(r"encoder\.subsampling\.layers\.\d+\.weight", name):
            value = value.transpose(0, 2, 3, 1)
        if re.search(r"conv\.(depthwise_conv|pointwise_conv[12])\.weight$", name):
            value = value.transpose(0, 2, 1)
        new_name = name
        for pattern, replacement in RENAMES:
            new_name = re.sub(pattern, replacement, new_name)
        if new_name in out:
            raise ValueError(f"Duplicate converted name: {new_name}")
        out[new_name] = value
    for name, biases in lstm_bias.items():
        assert len(biases) == 2, (name, len(biases))
        out[name] = (biases[0] + biases[1]).astype(mx.bfloat16)
    return out, skipped
def convert_bark(source_dir, output_dir):
    SOURCE = pathlib.Path(source_dir)
    Q8 = pathlib.Path(output_dir)
    BF16 = Q8.parent / "bf16-reference"
    source = mx.load(str(SOURCE / "model.safetensors"))
    config = json.loads((SOURCE / "mlx/config.json").read_text())
    config.update(model_type="parakeet", target="nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel",
                  dtype="bfloat16", _name_or_path="ConwayResearch/Underdog-Bark-3.0-Pro",
                  source_revision="4b5c51e04aa8d16dda9ecdff71bc29f7360149e4")
    config["decoding"] = {"strategy": "greedy_batch", "model_type": "tdt",
                          "durations": [0, 1, 2, 3, 4], "greedy": {"max_symbols": 10}}
    model = Model(ModelConfig.from_dict(config))
    expected = dict(tree_flatten(model.parameters()))
    weights, skipped = map_weights(source)
    assert set(weights) == set(expected), {"missing": sorted(set(expected)-set(weights)), "extra": sorted(set(weights)-set(expected))}
    for name, value in weights.items():
        assert value.shape == expected[name].shape, (name, value.shape, expected[name].shape)
    model.load_weights(list(weights.items()), strict=True)
    mx.eval(model.parameters())
    BF16.mkdir(parents=True, exist_ok=True)
    mx.save_safetensors(str(BF16 / "model.safetensors"), weights)
    (BF16 / "config.json").write_text(json.dumps(config, indent=2)+"\n")
    for f in ["tokenizer.json", "tokenizer_config.json", "NOTICE"]:
        shutil.copy2(SOURCE / f, BF16 / f)
    mapping = {"source_tensors": len(source), "converted_tensors": len(weights),
               "excluded_training_buffers": skipped,
               "converted_parameter_count": sum(v.size for v in weights.values()),
               "name_mapping_reference": "ConwayResearch/Underdog-Bark-3.0/bark_mlx.py",
               "changes": ["HF-to-NeMo key mapping", "channels-last convolution layouts",
                           "fused LSTM bias computed in FP32 then cast to BF16"]}
    print("Strict BF16 mapping passed:", json.dumps(mapping), flush=True)

    del source, weights, expected, model
    mx.clear_cache()
    convert(hf_path=str(BF16), mlx_path=str(Q8), quantize=True,
            q_group_size=64, q_bits=8, q_mode="affine", model_domain="stt")
    shutil.copy2(SOURCE / "NOTICE", Q8 / "NOTICE")
    restored = load(str(Q8), strict=True)
    mx.eval(restored.parameters())
    quantized = dict(tree_flatten(restored.parameters()))
    quant_modules = sorted(name[:-7] for name in quantized if name.endswith(".scales"))
    assert quant_modules, "No quantized modules found"
    stats = {"format": "MLX affine 8-bit", "bits": 8, "group_size": 64,
             "source_weight_bytes": (SOURCE/"model.safetensors").stat().st_size,
             "bf16_weight_bytes": (BF16/"model.safetensors").stat().st_size,
             "quantized_weight_bytes": (Q8/"model.safetensors").stat().st_size,
             "quantized_modules": quant_modules, "strict_reload": True,
             "source_preserved": True, "model_path": str(Q8),
             "quantized_sha256": hashlib.file_digest((Q8/"model.safetensors").open("rb"),"sha256").hexdigest(),
             "remaining_float_dtypes": sorted({str(v.dtype) for v in quantized.values() if mx.issubdtype(v.dtype,mx.floating)})}
    (Q8/"conversion.json").write_text(json.dumps(stats,indent=2)+"\n")
    print("Quantized model reloaded successfully", json.dumps(stats), flush=True)
