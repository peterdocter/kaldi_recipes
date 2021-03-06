#!/bin/bash

# Begin configuration section.
mode=4
cmd=run.pl
skip_scoring=false
# End configuration section.

echo "$0 $@"  # Print the command line for logging

. ./utils/parse_options.sh

if [ $# != 5 ]; then
   echo "Do language model rescoring of lattices (remove old LM, add new LM)"
   echo "Usage: steps/lmrescore.sh [options] <old-lang-dir> <new-lang-dir> <data-dir> <input-decode-dir> <output-decode-dir>"
   echo "options: [--cmd (run.pl|queue.pl [queue opts])] [--mode (1|2|3|4)]"
   exit 1;
fi

[ -f path.sh ] && . ./path.sh;

oldlang=$1
newlang=$2
data=$3
indir=$4
outdir=$5

oldlm=$oldlang/G.fst
newlm=$newlang/G.fst
! cmp $oldlang/words.txt $newlang/words.txt && echo "Warning: vocabularies may be incompatible."
[ ! -f $oldlm ] && echo Missing file $oldlm && exit 1;
[ ! -f $newlm ] && echo Missing file $newlm && exit 1;
! ls $indir/lat.*.gz >/dev/null && echo "No lattices input directory $indir" && exit 1;

if ! cmp -s $oldlang/words.txt $newlang/words.txt; then
  echo "$0: $oldlang/words.txt and $newlang/words.txt differ: make sure you know what you are doing.";
fi

oldlmcommand="fstproject --project_output=true $oldlm |"
newlmcommand="fstproject --project_output=true $newlm |"

mkdir -p $outdir/log

phi=`grep -w '#0' $newlang/words.txt | awk '{print $2}'`

if [ "$mode" == 4 ]; then
  # we have to prepare $outdir/Ldet.fst in this case: determinized
  # lexicon (determinized on phones), with disambig syms removed.
  # take L_disambig.fst; get rid of transition with "#0 #0" on it; determinize
  # with epsilon removal; remove disambiguation symbols.
  fstprint $newlang/L_disambig.fst | awk '{if($4 != '$phi'){print;}}' | fstcompile | \
    fstdeterminizestar | fstrmsymbols $newlang/phones/disambig.int >$outdir/Ldet.fst || exit 1;
fi

nj=`cat $indir/num_jobs` || exit 1;
cp $indir/num_jobs $outdir


#for lat in $indir/lat.*.gz; do
#  number=`basename $lat | cut -d. -f2`;
#  newlat=$outdir/`basename $lat`

case "$mode" in
  1) # 1 is inexact, it's the original way of doing it.
    $cmd JOB=1:$nj $outdir/log/rescorelm.JOB.log \
      lattice-lmrescore --lm-scale=-1.0 "ark:gunzip -c $indir/lat.JOB.gz|" "$oldlmcommand" ark:-  \| \
      lattice-lmrescore --lm-scale=1.0 ark:- "$newlmcommand" "ark,t:|gzip -c>$outdir/lat.JOB.gz" \
      || exit 1;
    ;;
  2)  # 2 is equivalent to 1, but using more basic operations, combined.
    $cmd JOB=1:$nj $outdir/log/rescorelm.JOB.log \
      gunzip -c $indir/lat.JOB.gz \| \
      lattice-scale --acoustic-scale=-1 --lm-scale=-1 ark:- ark:- \| \
      lattice-compose ark:- "fstproject --project_output=true $oldlm |" ark:- \| \
      lattice-determinize ark:- ark:- \| \
      lattice-scale --acoustic-scale=-1 --lm-scale=-1 ark:- ark:- \| \
      lattice-compose ark:- "fstproject --project_output=true $newlm |" ark:- \| \
      lattice-determinize ark:- ark:- \| \
      gzip -c \>$outdir/lat.JOB.gz || exit 1;
    ;;
  3) # 3 is "exact" in that we remove the old LM scores accepting any path
     # through G.fst (which is what we want as that happened in lattice
     # generation), but we add the new one with "phi matcher", only taking
     # backoff arcs if an explicit arc did not exist.
    $cmd JOB=1:$nj $outdir/log/rescorelm.JOB.log \
      gunzip -c $indir/lat.JOB.gz \| \
      lattice-scale --acoustic-scale=-1 --lm-scale=-1 ark:- ark:- \| \
      lattice-compose ark:- "fstproject --project_output=true $oldlm |" ark:- \| \
      lattice-determinize ark:- ark:- \| \
      lattice-scale --acoustic-scale=-1 --lm-scale=-1 ark:- ark:- \| \
      lattice-compose --phi-label=$phi ark:- $newlm ark:- \| \
      lattice-determinize ark:- ark:- \| \
      gzip -c \>$outdir/lat.JOB.gz || exit 1;
    ;;
  4) # 4 is also exact (like 3), but instead of subtracting the old LM-scores,
     # it removes the old graph scores entirely and adds in the lexicon,
     # grammar and transition weights.
    mdl=`dirname $indir`/final.mdl
    [ ! -f $mdl ] && echo No such model $mdl && exit 1;
    $cmd JOB=1:$nj $outdir/log/rescorelm.JOB.log \
      gunzip -c $indir/lat.JOB.gz \| \
      lattice-scale --lm-scale=0.0 ark:- ark:- \| \
      lattice-to-phone-lattice $mdl ark:- ark:- \| \
      lattice-compose ark:- $outdir/Ldet.fst ark:- \| \
      lattice-determinize ark:- ark:- \| \
      lattice-compose --phi-label=$phi ark:- $newlm ark:- \| \
      lattice-add-trans-probs --transition-scale=1.0 --self-loop-scale=0.1 \
      $mdl ark:- ark:- \| \
      gzip -c \>$outdir/lat.JOB.gz  || exit 1;
    ;;
esac

rm $outdir/Ldet.fst 2>/dev/null

if ! $skip_scoring ; then
  [ ! -x local/score.sh ] && \
    echo "Not scoring because local/score.sh does not exist or not executable." && exit 1;
  local/score.sh --cmd "$cmd" $data $newlang $outdir
else
  echo "Not scoring because requested so..."
fi

exit 0;
