# Builds train_hey_mibo.ipynb (run: python3 make_notebook.py).
# The notebook trains the "Hey Mibo" wake word for the Mibo Voice speaker on
# Google Colab, using microWakeWord (github.com/kahrendt/microWakeWord).
import json

cells = []
def md(s): cells.append({"cell_type": "markdown", "metadata": {}, "source": s.strip("\n")})
def code(s): cells.append({"cell_type": "code", "metadata": {}, "execution_count": None, "outputs": [], "source": s.strip("\n")})

md("""
# Train the "Hey Mibo" wake word

This makes the two files the Mibo Voice speaker needs: **hey_mibo.tflite** and **hey_mibo.json**.

1. **Runtime → Change runtime type → T4 GPU**, then Save.
2. **Runtime → Run all.** The first cell installs the tools and restarts the session by itself (Colab may say it crashed; that's expected).
3. **Runtime → Run all** again. This run takes about 1½–2 hours, mostly in the last training step. Keep the tab open.
4. At the end, your browser downloads **hey_mibo.zip**. Unzip it and follow the setup steps for the speaker.

Halfway down there's a cell that plays a few computer-voice samples of "Hey Mibo", so you can check they sound like "MEE-bo".

Note: the background-noise recordings used for training are for non-commercial use only, so this wake word is for your own home. A wake word for a product you sell would need commercially licensed recordings.
""")

code("""
# 1. Install the training tools (the session restarts once, after the first install).
import os
if not os.path.exists("/content/.mibo_tools_installed"):
    !git clone -q https://github.com/rhasspy/piper-sample-generator
    !pip install -q piper-sample-generator
    !pip install -q 'git+https://github.com/whatsnowplaying/audio-metadata@d4ebb238e6a401bb1a5aaaac60c9e2b3cb30929f'
    !git clone -q https://github.com/kahrendt/microWakeWord
    !pip install -q -e ./microWakeWord
    # Versions that work together (tested Nov 2026).
    !pip install -q -U audiomentations 'datasets<4' soundfile librosa tensorboard
    open("/content/.mibo_tools_installed", "w").write("ok")
    print("Installed. Restarting the session now; then choose Runtime > Run all again.")
    os.kill(os.getpid(), 9)

import torch
print("GPU ready:", torch.cuda.is_available())
if not torch.cuda.is_available():
    print("No GPU! Choose Runtime > Change runtime type > T4 GPU, or this will take many hours.")
""")

code("""
# 2. The voice generator that speaks the training samples (900+ different voices).
import os
GENERATOR = "piper-sample-generator/models/en_US-libritts_r-medium.pt"
if not os.path.exists(GENERATOR):
    !wget -q -O {GENERATOR} 'https://github.com/rhasspy/piper-sample-generator/releases/download/v2.0.0/en_US-libritts_r-medium.pt'

# Ways of writing "Hey Mibo" so the computer voices say MEE-bo (light o).
WAKE_PHRASES = ["hey meebo", "Hey Meebo.", "Hey, Meebo!", "hey mee bo", "Hey meebo?", "hey meebow"]

# Things that sound a bit like it, which must NOT wake the speaker.
NOT_WAKE = [
    "hey jimbo", "hey jumbo", "hey dumbo", "hey bimbo", "hey rambo", "hey gizmo", "hey nemo", "hey memo",
    "hey milo", "hey mabel", "hey mira", "hey mama", "hey baby", "hey buddy", "hey bo", "hey me",
    "hey elbow", "hey neighbor", "maybe so", "me too", "rainbow", "hey siri", "hey google", "hey jarvis",
    "okay nabu", "hey you", "hey there", "hey mike", "hey leo", "a bimbo", "hey bingo", "TV remote",
]
open("wake_phrases.txt", "w").write("\\n".join(WAKE_PHRASES) + "\\n")
open("not_wake.txt", "w").write("\\n".join(NOT_WAKE) + "\\n")
""")

code("""
# 3. Listen: a few samples of "Hey Mibo" in different voices.
from IPython.display import Audio, display
!PYTHONPATH=piper-sample-generator python3 -m piper_sample_generator wake_phrases.txt --model {GENERATOR} --max-samples 6 --batch-size 6 --max-speakers 500 --output-dir listen_check
for i in range(6):
    display(Audio(f"listen_check/{i}.wav"))
""")

code("""
# 4. Make the training samples (about 10 minutes on a T4).
!PYTHONPATH=piper-sample-generator python3 -m piper_sample_generator wake_phrases.txt --model {GENERATOR} --max-samples 12000 --batch-size 100 --max-speakers 500 \\
    --length-scales 0.8 0.9 1.0 1.1 1.25 --slerp-weights 0.3 0.5 0.7 --output-dir wake_samples
!PYTHONPATH=piper-sample-generator python3 -m piper_sample_generator not_wake.txt --model {GENERATOR} --max-samples 6000 --batch-size 100 --max-speakers 500 \\
    --length-scales 0.85 1.0 1.15 --slerp-weights 0.3 0.5 0.7 --output-dir not_wake_samples
""")

code("""
# 5. Room echoes, background noise and music to mix in (from Hugging Face; can be slow).
import datasets, scipy, os
import numpy as np
from pathlib import Path
from tqdm import tqdm

if not os.path.exists("mit_rirs"):
    os.mkdir("mit_rirs")
    rir = datasets.load_dataset("davidscripka/MIT_environmental_impulse_responses", split="train", streaming=True)
    for row in tqdm(rir):
        name = row["audio"]["path"].split("/")[-1]
        scipy.io.wavfile.write(os.path.join("mit_rirs", name), 16000, (row["audio"]["array"] * 32767).astype(np.int16))

if not os.path.exists("audioset_16k"):
    os.makedirs("audioset", exist_ok=True)
    !wget -q -O audioset/bal_train09.tar https://huggingface.co/datasets/agkphysics/AudioSet/resolve/main/data/bal_train09.tar
    !cd audioset && tar -xf bal_train09.tar
    os.mkdir("audioset_16k")
    ds = datasets.Dataset.from_dict({"audio": [str(i) for i in Path("audioset/audio").glob("**/*.flac")]}).cast_column("audio", datasets.Audio(sampling_rate=16000))
    for row in tqdm(ds):
        name = row["audio"]["path"].split("/")[-1].replace(".flac", ".wav")
        scipy.io.wavfile.write(os.path.join("audioset_16k", name), 16000, (row["audio"]["array"] * 32767).astype(np.int16))

if not os.path.exists("fma_16k"):
    os.makedirs("fma", exist_ok=True)
    !wget -q -O fma/fma_xs.zip https://huggingface.co/datasets/mchl914/fma_xsmall/resolve/main/fma_xs.zip
    !cd fma && unzip -q fma_xs.zip
    os.mkdir("fma_16k")
    ds = datasets.Dataset.from_dict({"audio": [str(i) for i in Path("fma/fma_small").glob("**/*.mp3")]}).cast_column("audio", datasets.Audio(sampling_rate=16000))
    for row in tqdm(ds):
        name = row["audio"]["path"].split("/")[-1].replace(".mp3", ".wav")
        scipy.io.wavfile.write(os.path.join("fma_16k", name), 16000, (row["audio"]["array"] * 32767).astype(np.int16))
print("Echoes:", len(os.listdir("mit_rirs")), " Noise:", len(os.listdir("audioset_16k")), " Music:", len(os.listdir("fma_16k")))
""")

code("""
# 6. Mix the samples with the room sounds and turn them into the speaker's audio features.
import os
from microwakeword.audio.augmentation import Augmentation
from microwakeword.audio.clips import Clips
from microwakeword.audio.spectrograms import SpectrogramGeneration
from mmap_ninja.ragged import RaggedMmap

augmenter = Augmentation(
    augmentation_duration_s=3.2,
    augmentation_probabilities={
        "SevenBandParametricEQ": 0.1, "TanhDistortion": 0.1, "PitchShift": 0.1, "BandStopFilter": 0.1,
        "AddColorNoise": 0.1, "AddBackgroundNoise": 0.75, "Gain": 1.0, "RIR": 0.5,
    },
    impulse_paths=["mit_rirs"],
    background_paths=["fma_16k", "audioset_16k"],
    background_min_snr_db=-5,
    background_max_snr_db=10,
    min_jitter_s=0.195,
    max_jitter_s=0.205,
)

def make_features(sample_dir, out_root):
    clips = Clips(input_directory=sample_dir, file_pattern="*.wav", max_clip_duration_s=None,
                  remove_silence=False, random_split_seed=10, split_count=0.1)
    for split, name, rep, slide in [("training", "train", 2, 10), ("validation", "validation", 1, 10), ("testing", "test", 1, 1)]:
        out_dir = os.path.join(out_root, split)
        if os.path.exists(os.path.join(out_dir, "wakeword_mmap")):
            continue
        os.makedirs(out_dir, exist_ok=True)
        spectrograms = SpectrogramGeneration(clips=clips, augmenter=augmenter, slide_frames=slide, step_ms=10)
        RaggedMmap.from_generator(
            out_dir=os.path.join(out_dir, "wakeword_mmap"),
            sample_generator=spectrograms.spectrogram_generator(split=name, repeat=rep),
            batch_size=100,
            verbose=True,
        )

make_features("wake_samples", "wake_features")
make_features("not_wake_samples", "not_wake_features")
""")

code("""
# 7. Ready-made examples of speech, a dinner party and other sounds that must not wake it.
import os
if not os.path.exists("negative_datasets/speech"):
    os.makedirs("negative_datasets", exist_ok=True)
    for fname in ["dinner_party.zip", "dinner_party_eval.zip", "no_speech.zip", "speech.zip"]:
        !wget -q -O negative_datasets/{fname} https://huggingface.co/datasets/kahrendt/microwakeword/resolve/main/{fname}
        !unzip -q -o negative_datasets/{fname} -d negative_datasets
print(os.listdir("negative_datasets"))
""")

code("""
# 7b. Use less memory when checking progress during training (free Colab has about 12 GB).
p = "microWakeWord/microwakeword/data.py"
s = open(p).read()
old = \"\"\"                for spectrogram in generator:
                    data.append(spectrogram)\"\"\"
new = \"\"\"                for n, spectrogram in enumerate(generator):
                    if n >= 8000 and mode in ("validation", "testing"):
                        break
                    data.append(spectrogram)\"\"\"
if "n >= 8000" in s:
    print("Already done.")
elif old in s:
    open(p, "w").write(s.replace(old, new))
    print("Done.")
else:
    print("Couldn't find the spot to change. Send Claude a screenshot.")
""")

code("""
# 8. Train (about an hour on a T4; Colab may look stuck for minutes at a time).
import yaml
config = {
    "window_step_ms": 10,
    "train_dir": "trained_models/hey_mibo",
    "features": [
        {"features_dir": "wake_features", "sampling_weight": 2.0, "penalty_weight": 1.0, "truth": True, "truncation_strategy": "truncate_start", "type": "mmap"},
        {"features_dir": "not_wake_features", "sampling_weight": 6.0, "penalty_weight": 1.0, "truth": False, "truncation_strategy": "truncate_start", "type": "mmap"},
        {"features_dir": "negative_datasets/speech", "sampling_weight": 10.0, "penalty_weight": 1.0, "truth": False, "truncation_strategy": "random", "type": "mmap"},
        {"features_dir": "negative_datasets/dinner_party", "sampling_weight": 10.0, "penalty_weight": 1.0, "truth": False, "truncation_strategy": "random", "type": "mmap"},
        {"features_dir": "negative_datasets/no_speech", "sampling_weight": 5.0, "penalty_weight": 1.0, "truth": False, "truncation_strategy": "random", "type": "mmap"},
        {"features_dir": "negative_datasets/dinner_party_eval", "sampling_weight": 0.0, "penalty_weight": 1.0, "truth": False, "truncation_strategy": "split", "type": "mmap"},
    ],
    "training_steps": [20000],
    "positive_class_weight": [1],
    "negative_class_weight": [20],
    "learning_rates": [0.001],
    "batch_size": 128,
    "time_mask_max_size": [0],
    "time_mask_count": [0],
    "freq_mask_max_size": [0],
    "freq_mask_count": [0],
    "eval_step_interval": 500,
    "clip_duration_ms": 1500,
    "target_minimization": 0.9,
    "minimization_metric": None,
    "maximization_metric": "average_viable_recall",
}
yaml.dump(config, open("training_parameters.yaml", "w"))

!python -m microwakeword.model_train_eval \\
    --training_config='training_parameters.yaml' \\
    --train 1 \\
    --restore_checkpoint 1 \\
    --test_tf_nonstreaming 0 \\
    --test_tflite_nonstreaming 0 \\
    --test_tflite_nonstreaming_quantized 0 \\
    --test_tflite_streaming 0 \\
    --test_tflite_streaming_quantized 1 \\
    --use_weights "best_weights" \\
    mixednet \\
    --pointwise_filters "64,64,64,64" \\
    --repeat_in_block "1, 1, 1, 1" \\
    --mixconv_kernel_sizes '[5], [7,11], [9,15], [23]' \\
    --residual_connection "0,0,0,0" \\
    --first_conv_filters 32 \\
    --first_conv_kernel_size 5 \\
    --stride 3
""")

code("""
# 9. Package hey_mibo.tflite and hey_mibo.json and download them.
import json, shutil, os
os.makedirs("hey_mibo", exist_ok=True)
shutil.copy("trained_models/hey_mibo/tflite_stream_state_internal_quant/stream_state_internal_quant.tflite", "hey_mibo/hey_mibo.tflite")
json.dump({
    "type": "micro",
    "wake_word": "Hey Mibo",
    "author": "Jim",
    "website": "https://ai.liljimjim.com",
    "model": "hey_mibo.tflite",
    "trained_languages": ["en"],
    "version": 2,
    "micro": {
        "probability_cutoff": 0.85,
        "feature_step_size": 10,
        "sliding_window_size": 5,
        "tensor_arena_size": 32000,
        "minimum_esphome_version": "2024.7.0",
    },
}, open("hey_mibo/hey_mibo.json", "w"), indent=2)
shutil.make_archive("hey_mibo", "zip", ".", "hey_mibo")
try:
    from google.colab import files
    files.download("hey_mibo.zip")
except ImportError:
    print("Made hey_mibo.zip")
""")

nb = {
    "cells": cells,
    "metadata": {
        "accelerator": "GPU",
        "colab": {"provenance": [], "gpuType": "T4"},
        "kernelspec": {"display_name": "Python 3", "name": "python3"},
        "language_info": {"name": "python"},
    },
    "nbformat": 4,
    "nbformat_minor": 0,
}
for c in nb["cells"]:
    lines = c["source"].split("\n")
    c["source"] = [l + "\n" for l in lines[:-1]] + [lines[-1]]
json.dump(nb, open("train_hey_mibo.ipynb", "w"), indent=1)
print("wrote train_hey_mibo.ipynb with", len(cells), "cells")
