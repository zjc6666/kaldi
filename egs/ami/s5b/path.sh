export KALDI_ROOT=`pwd`/../../..
[ -f $KALDI_ROOT/tools/env.sh ] && . $KALDI_ROOT/tools/env.sh
export PATH=$PWD/utils/:$KALDI_ROOT/tools/openfst/bin:$PWD:$PATH
[ ! -f $KALDI_ROOT/tools/config/common_path.sh ] && echo >&2 "The standard file $KALDI_ROOT/tools/config/common_path.sh is not present -> Exit!" && exit 1
. $KALDI_ROOT/tools/config/common_path.sh
export LC_ALL=C

LMBIN=$KALDI_ROOT/tools/irstlm/bin
SRILM=$KALDI_ROOT/tools/srilm/bin/i686-m64
BEAMFORMIT=$KALDI_ROOT/tools/BeamformIt

export PATH=$LMBIN:$BEAMFORMIT:$SRILM:$PATH
export PATH=$KALDI_ROOT/tools/sph2pipe_v2.5:$PATH
export PATH=/home/vmanoha1/kaldi-raw-signal/src/segmenterbin:$PATH
export PATH=$KALDI_ROOT/tools/sctk/bin:$PATH
export PYTHONPATH=${PYTHONPATH}:steps
