#!/bin/sh

################################################

pid=$$
date=`date '+%Y%m%d'`

maintePass=/home/radipi/repository/mainteRadipi
configFile=${maintePass}/systemConfig
authDir=${maintePass}/auth

#read systemConfig from [1]mail [2]fullPath [3]playerURL [4]loginURL
. ${configFile}


################################################

if [ -z "${fullPath}" ]; then
	fullPath=/home/radipi/recData
	mkdir -p ${fullPath}
fi

tmpPath=/tmp

playerfile=${tmpPath}/player.swf
keyfile=${tmpPath}/authkey_${pid}.png
auth1_fms=${tmpPath}/auth1_fms_${pid}
auth2_fms=${tmpPath}/auth2_fms_${pid}
cookiefile=${tmpPath}/pre_cookie_${pid}_${date}.txt
loginfile=${tmpPath}/pre_login.txt

secretKey=${authDir}/seckey
cipherText=${authDir}/cipher
pass=$(openssl rsautl -decrypt -inkey ${secretKey} -in ${cipherText})

################################################

if [ $# -le 1 ]; then
	echo "usage : $0 stationID duration[minuites] prefix"
	echo "ex) $0 TBS 120 ijuin"
  exit 1
fi

if [ $# -ge 3 ]; then
  stationID=$1
  DURATION=`expr $2 \* 60`
  PREFIX=$3
fi

################################################

fileBaseName=${date}_${PREFIX}
fullMP3Path=${fullPath}/${fileBaseName}.mp3

stationXML=${tmpPath}/${stationID}${pid}.xml
savefile=${tmpPath}/${fileBaseName}

################################################

###
# radiko premium
###

if [ $mail ]; then
  wget -q --save-cookie=$cookiefile \
       --keep-session-cookies \
       --post-data="mail=${mail}&pass=${pass}" \
       -O ${loginfile} \
       ${loginURL}

  if [ ! -f $cookiefile ]; then
    echo "failed login"
    exit 1
  fi
fi

#
# get player
#

if [ ! -f $playerfile ]; then
  wget -O ${playerfile} ${playerURL}
  if [ ! -f ${playerfile} ]; then
    echo "[stop] failed get player (${playerfile})" 1>&2 ; exit 1
  fi
fi

#
# get keydata (need swftool)
#

if [ ! -f ${keyfile} ]; then
  swfextract -b 12 ${playerfile} -o ${keyfile}
  if [ ! -f ${keyfile} ]; then
    echo "[stop] failed get keydata (${keyfile})" 1>&2 ; exit 1
  fi
fi

#
# access auth1_fms
#
wget -q \
     --header="pragma: no-cache" \
     --header="X-Radiko-App: pc_ts" \
     --header="X-Radiko-App-Version: 4.0.0" \
     --header="X-Radiko-User: test-stream" \
     --header="X-Radiko-Device: pc" \
     --post-data='\r\n' \
     --no-check-certificate \
     --load-cookies $cookiefile \
     --save-headers \
     -O ${auth1_fms} \
     https://radiko.jp/v2/api/auth1_fms

if [ $? -ne 0 ]; then
  echo "[stop] failed auth1 process (${auth1_fms})" 1>&2 ; exit 1
fi

#
# get partial key
#

authtoken=`perl -ne 'print $1 if(/x-radiko-authtoken: ([\w-]+)/i)' ${auth1_fms}`
offset=`perl -ne 'print $1 if(/x-radiko-keyoffset: (\d+)/i)' ${auth1_fms}`
length=`perl -ne 'print $1 if(/x-radiko-keylength: (\d+)/i)' ${auth1_fms}`

partialkey=`dd if=$keyfile bs=1 skip=${offset} count=${length} 2> /dev/null | base64`

echo "authtoken: ${authtoken} \noffset: ${offset} length: ${length} \npartialkey: $partialkey"

rm -f ${auth1_fms}

#
# access auth2_fms
#
wget -q \
     --header="pragma: no-cache" \
     --header="X-Radiko-App: pc_ts" \
     --header="X-Radiko-App-Version: 4.0.0" \
     --header="X-Radiko-User: test-stream" \
     --header="X-Radiko-Device: pc" \
     --header="X-Radiko-Authtoken: ${authtoken}" \
     --header="X-Radiko-Partialkey: ${partialkey}" \
     --post-data='\r\n' \
     --load-cookies $cookiefile \
     --no-check-certificate \
     -O ${auth2_fms} \
     https://radiko.jp/v2/api/auth2_fms

if [ $? -ne 0 -o ! -f ${auth2_fms} ]; then
  echo "[stop] failed auth2 process (${auth2_fms})" 1>&2 ; exit 1
fi

echo "authentication success"

areaid=`perl -ne 'print $1 if(/^([^,]+),/i)' ${auth2_fms}`
echo "areaid: $areaid"

rm -f ${auth2_fms}

#
# get stream-url
#

wget -q \
	--load-cookies $cookiefile \
	--no-check-certificate \
	-O ${stationXML} \
    "https://radiko.jp/v2/station/stream/${stationID}.xml"

  if [ $? -ne 0 -o ! -f ${stationXML} ]; then
      echo "[stop] failed stream-url process (stationID=${stationID})"
      rm -f ${stationXML} ; exit 1
  fi

  stream_url=`echo "cat /url/item[1]/text()" | \
          xmllint --shell ${stationXML} | tail -2 | head -1`
  url_parts=(`echo ${stream_url} | \
          perl -pe 's!^(.*)://(.*?)/(.*)/(.*?)$/!$1://$2 $3 $4!'`)
  rm -f ${stationXML}

	echo "[url_parts0] ${url_parts[0]}"
	echo "[url_parts1] ${url_parts[1]}"
	echo "[url_parts2] ${url_parts[2]}"

rm -f ${keyfile}
rm -f ${auth1_fms}
rm -f ${auth2_fms}
rm -f ${cookiefile}



################################################

# record files
/usr/bin/rtmpdump \
         -r ${url_parts[0]} \
         --app ${url_parts[1]} \
         --playpath ${url_parts[2]} \
         -W $playerURL \
         -C S:"" -C S:"" -C S:"" -C S:$authtoken \
         --live \
         --quiet \
         --stop ${DURATION} \
         --flv ${savefile}

# convert localfile to mp3
ffmpeg -loglevel warning -y -i "${savefile}" -acodec libmp3lame -ab 64k "${fullMP3Path}"

# delete localfile
if [ $? = 0 ]; then
	rm -f ${savefile};
fi

echo "[recFile]${fullMP3Path}"
