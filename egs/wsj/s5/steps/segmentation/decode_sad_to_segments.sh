#! /bin/bash

stage=-1
segmentation_config=conf/segmentation.conf
cmd=run.pl

# Viterbi options
min_silence_duration=30   # minimum number of frames for silence
min_speech_duration=30    # minimum number of frames for speech
nonsil_transition_probability=0.1
sil_transition_probability=0.1
sil_prior=0.5
speech_prior=0.5

# Decoding options
acwt=1
beam=10
max_active=7000

. utils/parse_options.sh

if [ $# -ne 4 ]; then
  echo "Usage: $0 <data> <sad-likes-dir> <segmentation-dir> <segmented-data-dir>"
  echo " e.g.: $0 data/babel_bengali_dev10h exp/nnet3_sad_snr/tdnn_b_n4/sad_babel_bengali_dev10h exp/nnet3_sad_snr/tdnn_b_n4/segmentation_babel_bengali_dev10h exp/nnet3_sad_snr/tdnn_b_n4/segmentation_babel_bengali_dev10h/babel_bengali_dev10h.seg"
  exit 1
fi

data=$1
sad_likes_dir=$2
dir=$3
out_data=$4

t=sil${sil_prior}_sp${speech_prior}
lang=$dir/lang_test_${t}

if [ $stage -le 1 ]; then
  mkdir -p $lang

  steps/segmentation/internal/prepare_sad_lang.py \
    --phone-transition-parameters="--phone-list=1 --min-duration=$min_silence_duration --end-transition-probability=$sil_transition_probability" \
    --phone-transition-parameters="--phone-list=2 --min-duration=$min_speech_duration --end-transition-probability=$nonsil_transition_probability" $lang

  cp $lang/phones.txt $lang/words.txt
fi

feat_dim=2    # dummy. We don't need this.
if [ $stage -le 2 ]; then
  $cmd $dir/log/create_transition_model.log gmm-init-mono \
    $lang/topo $feat_dim - $dir/tree \| \
    copy-transition-model --binary=false - $dir/trans.mdl || exit 1
fi

if [ $stage -le 3 ]; then
  cat > $lang/word2prior <<EOF
1 $sil_prior
2 $speech_prior
EOF
  steps/segmentation/internal/make_G_fst.py --word2prior-map $lang/word2prior | \
    fstcompile --isymbols=$lang/words.txt --osymbols=$lang/words.txt \
    --keep_isymbols=false --keep_osymbols=false \
    > $lang/G.fst
fi

graph_dir=$dir/graph_test_${t}

if [ $stage -le 4 ]; then
  $cmd $dir/log/make_vad_graph.log \
    steps/segmentation/internal/make_sad_graph.sh --iter trans \
    $lang $dir $dir/graph_test_${t} || exit 1
fi

if [ $stage -le 5 ]; then
  steps/segmentation/decode_sad.sh \
    --acwt $acwt --beam $beam --max-active $max_active \
    $graph_dir $sad_likes_dir $dir
fi

if [ $stage -le 6 ]; then
  cat > $lang/phone2sad_map <<EOF
1 0
2 1
EOF
  steps/segmentation/post_process_sad_to_segments.sh \
    --phone2sad-map $lang/phone2sad_map \
    --ali-suffix "" --segmentation-config $segmentation_config \
    $data $lang $dir $dir $out_data
fi

