#!/bin/sh
# Обновление базлайна нагрузки. Cron раз в час.
# Берёт сэмплы из tmpfs, считает средние по слотам «час суток» (0-23) для
# каждой метрики и EMA-обновляет компактный базлайн на флешке (раз в час —
# запись крошечного файла, износ флешки минимален). Затем очищает сэмплы.
#
# Формат базлайна: METRIC<TAB>SLOT<TAB>N<TAB>MEAN<TAB>MAD
# METRIC: cpu mem conn load wan ; SLOT: час суток 0-23.

DIR=/opt/etc/observer
TMP=/tmp/metrics
S="$TMP/samples.tsv"
BL="$DIR/state/baseline.tsv"

[ -s "$S" ] || exit 0
touch "$BL"

# Весь пересчёт — одним awk: грузим базлайн, агрегируем сэмплы по (метрика,слот),
# EMA-обновляем (alpha=0.2), печатаем новый базлайн.
awk -F'\t' -v alpha=0.2 -v blf="$BL" '
  BEGIN{ n=split("cpu:3 mem:4 conn:5 load:6 wan:7", arr, " ") }
  # различаем файлы по имени (FNR==NR ломается на пустом базлайне)
  FILENAME==blf{ k=$1 SUBSEP $2; bn[k]=$3; bmean[k]=$4; bmad[k]=$5; seen[k]=1; next }
  # сэмплы: колонка 2 = слот-час. Копим sum и sumsq для реального разброса.
  {
    for(i=1;i<=n;i++){ split(arr[i], kv, ":"); name=kv[1]; col=kv[2];
      k=name SUBSEP $2; sum[k]+=$col; sumsq[k]+=$col*$col; cnt[k]++ }
  }
  END{
    for(k in cnt){
      c=cnt[k]; avg=sum[k]/c
      var=sumsq[k]/c - avg*avg; if(var<0)var=0; sd=sqrt(var)   # реальный разброс за час
      if(k in bmean && seen[k]){
        nmean=bmean[k]+alpha*(avg-bmean[k])
        nspr =bmad[k] +alpha*(sd -bmad[k]); if(nspr<1)nspr=1
        nn=bn[k]+1; if(nn>999)nn=999
      } else {
        nmean=avg; nspr=(sd>1?sd:1); nn=1   # первичная норма: реальный mean и разброс из 12 замеров
      }
      bmean[k]=nmean; bmad[k]=nspr; bn[k]=nn; keep[k]=1
    }
    # сохранить и слоты, по которым в этот час не было сэмплов
    for(k in bmean) if(!(k in keep)) keep[k]=1
    for(k in keep){ split(k,a,SUBSEP);
      printf "%s\t%s\t%d\t%d\t%d\n", a[1], a[2], bn[k], bmean[k]+0.5, bmad[k]+0.5 }
  }
' "$BL" "$S" | sort -t"$(printf '\t')" -k1,1 -k2,2n > "$BL.new" && mv "$BL.new" "$BL"

# очистить накопленные сэмплы (следующий час копится заново)
: > "$S"
