#!/bin/bash
#SBATCH --job-name=gpt175b
#SBATCH --ntasks-per-node=1
#SBATCH --gpus-per-node=8
#SBATCH --cpus-per-task=8
#SBATCH --gpus-per-task=8
#SBATCH --mem=0
#SBATCH --output=gpt175b_%j.out
#SBATCH --error=gpt175b_%j.err
# Copyright (c) 2022, NVIDIA CORPORATION. All rights reserved.
# This script has been modified from https://github.com/NVIDIA/Megatron-LM/blob/main/examples/gpt3/train_gpt3_175b_distributed.sh
# It contains the procedure to run the training of GPT-3 175B model using Megatron-LM.
set -xe

if [ -z "$STAGE_PATH" ]; then
	echo "Please set the STAGE_PATH environment variable to the path where you want to store the image."
	exit 1
fi

## CONFIGURATION
TOPO_FILE=${TOPO_FILE:-"/opt/microsoft/ndv5-topo.xml"}
CHUNKS=${CHUNKS:-15}
GLOBAL_BATCH_SIZE=${GLOBAL_BATCH_SIZE:-512}
NUMBER_OF_ITERATIONS=${NUMBER_OF_ITERATIONS:-1500}
SAVE_INTERVAL=${SAVE_INTERVAL:-100}
EVAL_INTERVAL=${EVAL_INTERVAL:-100}
LOGLEVEL=${LOGLEVEL:-"INFO"}
NUM_LAYERS=${NUM_LAYERS:-96}
HIDDEN_SIZE=${HIDDEN_SIZE:-12288}
NUM_ATTENTION_HEADS=${NUM_ATTENTION_HEADS:-96}
SEQ_LENGTH=${SEQ_LENGTH:-2048}
TENSOR_MODEL_PARALLEL_SIZE=${TENSOR_MODEL_PARALLEL_SIZE:-8}
PIPELINE_MODEL_PARALLEL_SIZE=${PIPELINE_MODEL_PARALLEL_SIZE:-16}
USE_SHARP=${USE_SHARP:-0} # Set to 1 to use SHARP, 0 to disable it

export OMPI_MCA_coll_hcoll_enable=0 \
	CUDA_DEVICE_ORDER=PCI_BUS_ID \
	NCCL_SOCKET_IFNAME=eth0 \
	UCX_TLS=rc \
	UCX_NET_DEVICES=mlx5_ib0:1 \
	NCCL_DEBUG=INFO \
	NCCL_IB_PCI_RELAXED_ORDERING=1 \
	NCCL_IB_QPS_PER_CONNECTION=4 \
	NCCL_IGNORE_CPU_AFFINITY=1 \
	NCCL_P2P_NET_CHUNKSIZE=$((512 * 1024)) \
	NCCL_PXN_DISABLE=1 \
	NCCL_MIN_NCHANNELS=32

if [ "$USE_SHARP" -eq 1 ]; then
	SHARP_SMX_UCX_INTERFACE=mlx5_ib0:1 \
	SHARP_COLL_ENABLE_SAT=1 \
	SHARP_COLL_LOG_LEVEL=3 \
	SHARP_COLL_ENABLE_PCI_RELAXED_ORDERING=1 \
	NCCL_COLLNET_ENABLE=1
fi

export NCCL_TOPO_FILE=$TOPO_FILE
export CUDA_DEVICE_MAX_CONNECTIONS=1

## PYTORCH
PYTORCH_VERSION=${PYTORCH_VERSION:-"25.03"}
SQUASHED_PYTORCH_IMAGE_NAME="pytorch+${PYTORCH_VERSION}+py3"
SQUASHED_PYTORCH_IMAGE="$STAGE_PATH/${SQUASHED_PYTORCH_IMAGE_NAME}.sqsh"

## PATHS
DATASET_FOLDER_NAME=${DATASET_FOLDER_NAME:-"slimpajama/preprocessed"}
WORK_DIR=${WORK_DIR:-$STAGE_PATH/Megatron-LM}
DATA_PATH=${DATA_PATH:-$STAGE_PATH/$DATASET_FOLDER_NAME}
TENSORBOARD_LOGS_PATH=${TENSORBOARD_LOGS_PATH:-$STAGE_PATH/logs}
CHECKPOINT_PATH=${CHECKPOINT_PATH:-$STAGE_PATH/checkpoints}
VOCAB_FILE=${VOCAB_FILE:-$STAGE_PATH/slimpajama/bpe/vocab.json}
MERGE_FILE=${MERGE_FILE:-$STAGE_PATH/slimpajama/bpe/vocab.json}
DATA_CACHE_DIR=${DATA_CACHE_DIR:-$STAGE_PATH/datacache}

DATA_SET_SIZE=$(find $DATA_PATH -name "*.bin" -type f | wc -l)

readarray -t TRAIN_DATA < <(find $DATA_PATH -name "*.bin" -type f | sort | head -n $(($DATA_SET_SIZE - $CHUNKS - $CHUNKS)) | xargs -n 1 echo 1.0 | sed "s/.bin//g")

readarray -t VALID_DATA < <(find $DATA_PATH -name "*.bin" -type f | sort | tail -n $(($CHUNKS)) | xargs -n1 echo 1.0 | sed "s/.bin//g")

readarray -t TEST_DATA < <(find $DATA_PATH -name "*.bin" -type f | sort | tail -n $(($CHUNKS + $CHUNKS)) | head -n $(($CHUNKS)) | xargs -n1 echo 1.0 | sed "s/.bin//g")

DISTRIBUTED_ARGS=(
	--nproc_per_node "$SLURM_GPUS_PER_NODE"
	--nnodes "$SLURM_NNODES"
	--rdzv_id $RANDOM
	--rdzv_backend c10d
	--rdzv_endpoint "$(hostname)":29500
)

GPT_MODEL_ARGS=(
	--num-layers "$NUM_LAYERS"
	--hidden-size "$HIDDEN_SIZE"
	--num-attention-heads "$NUM_ATTENTION_HEADS"
	--seq-length "$SEQ_LENGTH"
	--max-position-embeddings 2048
	--attention-backend auto
)

TRAINING_ARGS=(
	--micro-batch-size 1
	--global-batch-size "$GLOBAL_BATCH_SIZE" #To be tuned based on number of GPUs. Suggested 16 x GPU number
	--train-iters "$NUMBER_OF_ITERATIONS"    # This is the number of iterations to train for. 1500 is a very low number
	--weight-decay 0.1
	--adam-beta1 0.9
	--adam-beta2 0.95
	--init-method-std 0.006
	--clip-grad 1.0
	--fp16
	--lr 6.0e-5
	--lr-decay-style cosine
	--min-lr 6.0e-6
	--lr-warmup-fraction .001
	--lr-decay-iters 430000
)

# Add --use-sharp flag only when SHARP is enabled
if [ "$USE_SHARP" -eq 1 ]; then
	TRAINING_ARGS+=(--use-sharp)
fi

MODEL_PARALLEL_ARGS=(
	--tensor-model-parallel-size "$TENSOR_MODEL_PARALLEL_SIZE"
	--pipeline-model-parallel-size "$PIPELINE_MODEL_PARALLEL_SIZE"
	--sequence-parallel
	--use-distributed-optimizer
)

DATA_ARGS=(
	--data-cache-path "$DATA_CACHE_DIR"
	--train-data-path $(echo "${TRAIN_DATA[@]}")
	--valid-data-path $(echo "${VALID_DATA[@]}")
	--test-data-path $(echo "${TEST_DATA[@]}")
	--vocab-file "$VOCAB_FILE"
	--merge-file "$MERGE_FILE"
)

EVAL_AND_LOGGING_ARGS=(
	--log-interval 10
	--save-interval "$SAVE_INTERVAL"
	--eval-interval "$EVAL_INTERVAL"
	--save "$CHECKPOINT_PATH"
	--load "$CHECKPOINT_PATH"
	--eval-iters 10
	--tensorboard-dir "$TENSORBOARD_LOGS_PATH"
	--ckpt-format torch_dist
	--ckpt-fully-parallel-load
	--use-persistent-ckpt-worker
	--ckpt-assume-constant-structure
)

mkdir -p "$CHECKPOINT_PATH"
mkdir -p "$TENSORBOARD_LOGS_PATH"
mkdir -p "$DATA_CACHE_DIR"

srun --container-mounts="$TOPO_FILE:$TOPO_FILE,$STAGE_PATH:$STAGE_PATH,$DATA_PATH:$DATA_PATH,$WORK_DIR:$WORK_DIR,$VOCAB_FILE:$VOCAB_FILE,$MERGE_FILE:$MERGE_FILE,$CHECKPOINT_PATH:$CHECKPOINT_PATH,/var/tmp:/var/tmp,/opt/microsoft:/opt/microsoft" \
	--container-env=CUDA_DEVICE_MAX_CONNECTIONS,NCCL_TOPO_FILE,LOGLEVEL \
	--container-image=$SQUASHED_PYTORCH_IMAGE \
	torchrun "${DISTRIBUTED_ARGS[@]}" $WORK_DIR/pretrain_gpt.py \
	"${GPT_MODEL_ARGS[@]}" \
	"${TRAINING_ARGS[@]}" \
	"${MODEL_PARALLEL_ARGS[@]}" \
	"${DATA_ARGS[@]}" \
	"${EVAL_AND_LOGGING_ARGS[@]}"
