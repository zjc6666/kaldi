#!/bin/bash

# This script can be used for training multilingual setup using different
# languages (specifically babel languages) with no shared phones.
# It will generates separate egs directory for each dataset and combine them
# during training.
# In the new multilingual training setup, mini-batches of data corresponding to
# different languages are randomly sampled egs.scp file, which are generated
# based on probability distribution that reflects the relative
# frequency of the data from each language.

# For all languages, we share all the hidden layers and there is separate final
# layer per language.
# The bottleneck layer can be added to network structure.

# The script requires you to have baseline PLP features for all languages.
# It generates 40dim MFCC + pitch features for all languages.

# The global iVector extractor is trained using all languages and the iVector
# extracts for all languages.

echo "$0 $@"  # Print the command line for logging
. ./cmd.sh
set -e

remove_egs=false
cmd=queue.pl
stage=0
train_stage=-10
get_egs_stage=-10
decode_stage=-10
num_jobs_initial=2
num_jobs_final=8
speed_perturb=true
use_pitch=true
use_ivector=true
global_extractor=exp/multi/nnet3/extractor
megs_dir=
alidir=tri5_ali
suffix=
feat_suffix=_hires_mfcc # The feature suffix describing features used in multilingual training
                        # _hires_mfcc -> 40dim MFCC
                        # _hire_mfcc_pitch -> 40dim MFCC + pitch
                        # _hires_mfcc_pitch_bnf -> 40dim MFCC +pitch + BNF
# corpora
# language list used for multilingual training
# The map for lang-name to its abreviation can be find in
# local/prepare_flp_langconf.sh
# e.g lang_list=(101-cantonese 102-assamese 103-bengali)
lang_list=(101-cantonese 102-assamese 103-bengali)
# The language in this list decodes using Hybrid multilingual system.
# e.g. decode_lang_list=(101-cantonese)
decode_lang_list=

dir=exp/nnet3/multi_bnf
ivector_suffix=_gb # if ivector_suffix = _gb, the iVector extracted using global iVector extractor
                   # trained on pooled data from all languages.
                   # Otherwise, it uses iVector extracted using local iVector extractor.
bnf_dim=256        # If non-empty, the bottleneck layer with this dimension is added at two layers before softmax.
. ./path.sh
. ./cmd.sh
. ./utils/parse_options.sh

[ -f local.conf ] && . ./local.conf

num_langs=${#lang_list[@]}

echo "$0 $@"  # Print the command line for logging
if ! cuda-compiled; then
  cat <<EOF && exit 1
This script is intended to be used with GPUs but you have not compiled Kaldi with CUDA
If you want to use GPUs (and have them), go to src/, and configure and make on a machine
where "nvcc" is installed.
EOF
fi

echo "$0: lang_list = ${lang_list[@]}"

for lang_index in `seq 0 $[$num_langs-1]`; do
  for f in data/${lang_list[$lang_index]}/train/{feats.scp,text} exp/${lang_list[$lang_index]}/$alidir/ali.1.gz exp/${lang_list[$lang_index]}/$alidir/tree; do
    [ ! -f $f ] && echo "$0: no such file $f" && exit 1;
  done
done

if [ "$speed_perturb" == "true" ]; then
  suffix=${suffix}_sp
fi

if $use_pitch; then feat_suffix=${feat_suffix}_pitch ; fi
dir=${dir}${suffix}

# extract high resolution MFCC features for speed-perturbed data
# and extract alignment
for lang_index in `seq 0 $[$num_langs-1]`; do
  echo "$0: extract 40dim MFCC + pitch for speed-perturbed data"
  local/nnet3/run_common_langs.sh --stage $stage \
    --speed-perturb $speed_perturb ${lang_list[$lang_index]} || exit;
done
# we use ivector extractor trained on pooled data from all languages
# using an LDA+MLLT transform arbitrarily chosen from single language.
if $use_ivector && [ ! -f $global_extractor/.done ]; then
  echo "$0: combine training data using all langs for training global i-vector extractor."
  if [ ! -f data/multi/train${suffix}_hires/.done ]; then
    echo ---------------------------------------------------------------------
    echo "Pooling training data in data/multi${suffix}_hires on" `date`
    echo ---------------------------------------------------------------------
    mkdir -p data/multi
    mkdir -p data/multi/train${suffix}_hires
    combine_lang_list=""
    for lang_index in `seq 0 $[$num_langs-1]`;do
      combine_lang_list="$combine_lang_list data/${lang_list[$lang_index]}/train${suffix}_hires"
    done
    utils/combine_data.sh data/multi/train${suffix}_hires $combine_lang_list
    utils/validate_data_dir.sh --no-feats data/multi/train${suffix}_hires
    touch data/multi/train${suffix}_hires/.done
  fi
  echo "$0: Generate global i-vector extractor using data/multi"
  local/nnet3/run_shared_ivector_extractor.sh --global-extractor $global_extractor \
    --stage $stage ${lang_list[0]} || exit 1;
  touch $global_extractor/.done

  echo "$0: Extract ivector for all languages."
  for lang_index in `seq 0 $[$num_langs-1]`; do
    local/nnet3/extract_ivector_lang.sh --stage $stage \
      --global-extractor $global_extractor \
      --train-set train$suffix ${lang_list[$lang_index]} || exit;
  done
fi


# set num_leaves for all languages
for lang_index in `seq 0 $[$num_langs-1]`; do
  multi_data_dirs[$lang_index]=data/${lang_list[$lang_index]}/train${suffix}${feat_suffix}
  multi_egs_dirs[$lang_index]=exp/${lang_list[$lang_index]}/nnet3/egs${ivector_suffix}
  multi_ali_dirs[$lang_index]=exp/${lang_list[$lang_index]}/tri5_ali${suffix}
  multi_ivector_dirs[$lang_index]=exp/${lang_list[$lang_index]}/nnet3/ivectors_train${suffix}${ivector_suffix}
done

if $use_ivector; then
  ivector_dim=$(feat-to-dim scp:${multi_ivector_dirs[0]}/ivector_online.scp -) || exit 1;
  echo ivector-dim = $ivector_dim
else
  echo "$0: Not using iVectors in multilingual training."
  ivector_dim=0
fi
feat_dim=`feat-to-dim scp:${multi_data_dirs[0]}/feats.scp -`


if [ $stage -le 9 ]; then
  echo "$0: creating multilingual neural net configs using the xconfig parser";

  if [ -z $bnf_dim ]; then
    bnf_dim=1024
  fi
  input_layer_dim=$[3*$feat_dim+$ivector_dim]
  mkdir -p $dir/configs
  cat <<EOF > $dir/configs/network.xconfig
  input dim=$ivector_dim name=ivector
  input dim=$feat_dim name=input
  output name=output-tmp input=Append(-1,0,1,ReplaceIndex(ivector, t, 0))

  # please note that it is important to have input layer with the name=input
  # as the layer immediately preceding the fixed-affine-layer to enable
  # the use of short notation for the descriptor
  # the first splicing is moved before the lda layer, so no splicing here
  relu-renorm-layer name=tdnn1 input=Append(input@-2,input@-1,input,input@1,input@2,ReplaceIndex(ivector, t, 0)) dim=$input_layer_dim
  relu-renorm-layer name=tdnn2 dim=1024
  relu-renorm-layer name=tdnn3 input=Append(-1,2) dim=1024
  relu-renorm-layer name=tdnn4 input=Append(-3,3) dim=1024
  relu-renorm-layer name=tdnn5 input=Append(-3,3) dim=1024
  relu-renorm-layer name=tdnn6 input=Append(-7,2) dim=1024
  relu-renorm-layer name=tdnn_bn dim=$bnf_dim
  # adding the layers for diffrent language's output
EOF
  # added separate outptut layer and softmax for all languages.
  for lang_index in `seq 0 $[$num_langs-1]`;do
    num_targets=`tree-info exp/${lang_list[$lang_index]}/$alidir/tree 2>/dev/null | grep num-pdfs | awk '{print $2}'` || exit 1;

    echo " relu-renorm-layer name=prefinal-affine-lang-${lang_index} input=tdnn7 dim=1024"
    echo " output-layer name=output-${lang_index} dim=$num_targets"
  done >> $dir/configs/network.xconfig

  steps/nnet3/xconfig_to_configs.py --xconfig-file $dir/configs/network.xconfig \
    --config-dir $dir/configs/ \
    --nnet-edits="rename-node old-name=output-0 new-name=output"

  cat <<EOF >> $dir/configs/vars
  add_lda=false
EOF

  # removing the extra output node "output-tmp" added for back-compatiblity with
  # xconfig to config conversion.
  nnet3-copy --edits="remove-output-nodes name=output-tmp" $dir/configs/ref.raw $dir/configs/ref.raw || exit 1;
fi

if [ $stage -le 10 ]; then
  echo "$0: Generates separate egs dir per language for multilingual training."
  # sourcing the "vars" below sets
  #model_left_context=(something)
  #model_right_context=(something)
  #num_hidden_layers=(something)
  . $dir/configs/vars || exit 1;
  ivec="${multi_ivector_dirs[@]}"
  if $use_ivector; then
    ivector_opts=(--online-multi-ivector-dirs "$ivec")
  fi
  local/nnet3/prepare_multilingual_egs.sh --cmd "$decode_cmd" \
    "${ivector_opts[@]}" \
    --left-context $model_left_context --right-context $model_right_context \
    --samples-per-iter 400000 \
    $num_langs ${multi_data_dirs[@]} ${multi_ali_dirs[@]} ${multi_egs_dirs[@]} || exit 1;

fi

if [ -z $megs_dir ];then
  megs_dir=$dir/egs
fi

if [ $stage -le 11 ] && [ -z $megs_dir ]; then
  echo "$0: Generate multilingual egs dir using "
       "separate egs dirs for multilingual training."
  common_egs_dir="${multi_egs_dirs[@]} $megs_dir"
  steps/nnet3/multilingual/get_egs.sh $egs_opts \
    --cmd "$decode_cmd" \
    --samples-per-iter 400000 \
    $num_langs ${common_egs_dir[@]} || exit 1;
fi

if [ $stage -le 12 ]; then
  steps/nnet3/train_raw_dnn.py --stage=$train_stage \
    --cmd="$decode_cmd" \
    --feat.cmvn-opts="--norm-means=false --norm-vars=false" \
    --trainer.num-epochs 2 \
    --trainer.optimization.num-jobs-initial 3 \
    --trainer.optimization.num-jobs-final 16 \
    --trainer.optimization.initial-effective-lrate 0.0017 \
    --trainer.optimization.final-effective-lrate 0.00017 \
    --feat-dir ${multi_data_dirs[0]} \
    --feat.online-ivector-dir ${multi_ivector_dirs[0]} \
    --egs.dir $megs_dir \
    --use-dense-targets false \
    --targets-scp ${multi_ali_dirs[0]} \
    --cleanup.remove-egs $remove_egs \
    --cleanup.preserve-model-interval 20 \
    --use-gpu true \
    --reporting.email="$reporting_email" \
    --dir=$dir  || exit 1;
fi

if [ $stage -le 13 ]; then
  for lang_index in `seq 0 $num_langs`;do
    echo "$0: compute average posterior and readjust priors for language ${lang_list[$lang_index]}."
    echo "alidir = ${multi_ali_dirs[$lang_index]} "
    lang_dir=$dir/${lang_list[$lang_index]}
    mkdir -p  $lang_dir
    # rename output name for each lang to 'output'.
    nnet3-copy --edits="rename-node old-name=output-$lang_index new-name=output" \
      $dir/final.raw $lang_dir/final.${lang_index}.raw || exit 1;

    steps/nnet3/compute_and_adjust_priors.py --cmd="$decode_cmd" \
      --egs.dir $megs_dir \
      --egs.use-multitask-egs true \
      --use-gpu true \
      --reporting.email="$reporting_email" \
      --post-process.model final.${lang_index} \
      --post-process.readjust-model final.${lang_index} \
      --post-process.readjust-priors true \
      --post-process.output-name output-${lang_index} \
      --ali-dir ${multi_ali_dirs[$lang_index]} \
      --dir=$lang_dir  || exit 1;
  done
fi

# decoding different languages
if [ $stage -le 13 ]; then
  num_decode_lang=${#decode_lang_list[@]}
  (
  for lang_index in `seq 0 $[$num_decode_lang-1]`; do
    if [ ! -f $dir/${decode_lang_list[$lang]}/decode_dev10h.pem/.done ]; then
      cp $dir/cmvn_opts $dir/${decode_lang_list[$lang]}/.
      echo "Decoding lang ${decode_lang_list[$lang]} using multilingual hybrid model $dir"
      run-4-anydecode-langs.sh --use-ivector $use_ivector --nnet3-dir $dir ${decode_lang_list[$lang]} || exit 1;
      touch $dir/${decode_lang_list[$lang]}/decode_dev10h.pem/.done
    fi
  done
  wait
  )
fi
