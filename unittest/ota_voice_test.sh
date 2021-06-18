#!/bin/bash
# ota_test.sh
#
# Automated Over The Air (OTA) voice test for FreeDV HF voice modes
#
# 1. Build codec2
# 2. Install kiwclient:
#    cd ~ && git clone git@github.com:jks-prv/kiwiclient.git
# 3. Install Hamlib cli tools

#
# TODO
# [ ] compression only test mode, to measure compression (maybe play back)
# [X] function to compress analog
# [X] function to concatenate analog and digital 
# [X] first Tx to SDR
# [X] inspect peak levels to ake sure they are the same
# [X] simple drop power test on local/no fading
#     + comparisons not straight forward
#     + SSB degrades and improves slowly with power
# [ ] split received file into SSB/FreeDV?
# [X] higher gain on analog
# [X] generate Octave plot of output speech
#     + Hmm not sure this is useful
#     + plot of sync/SNR might be better
#     + be good to tell from inspection of plot if it has decent audio
# [ ] worth logging/plotting SNR?

PATH=${PATH}:${HOME}/codec2/build_linux/src:${HOME}/kiwiclient
CODEC2=${HOME}/codec2

kiwi_url=""
port=8073
freq_kHz="7177"
tx_only=0
Nbursts=5
mode="700D"
model=361
gain=6
serialPort="/dev/ttyUSB0"

function print_help {
    echo
    echo "Automated Over The Air (OTA) voice test for FreeDV HF voice modes"
    echo
    echo "  usage ./ota_voice_test.sh [-d] [-f freq_kHz] [-g cgain] [-m mode] [-o model] [-p port] [-t] SpeechFile kiwi_url"
    echo
    echo "    -d        debug mode; trace script execution"
    echo "    -g        SSB (analog) compressor gain"
    echo "    -o model  select radio model number ('rigctl -l' to list)"
    echo "    -m mode   700c|700d|700e"
    echo "    -t        Tx only, useful for manually observing SDRs"
    echo "    -s port   The serial port (or hostname:port) to connect to for TX, default /dev/ttyUSB0"
    echo
    exit
}

# Approximation of Hilbert clipper type compressor 
function analog_compressor {
    input_file=$1
    output_file=$2
    gain=$3
    cat $input_file | cohpsk_ch - - -100 --Fs 8000 | \
    cohpsk_ch - - -100 --Fs 8000 --clip 16384 --gain $gain | \
    cohpsk_ch - - -100 --Fs 8000 --clip 16384 > $output_file
}

function run_rigctl {
    command=$1
    model=$2
    echo $command | rigctl -m $model -r $serialPort > /dev/null
    if [ $? -ne 0 ]; then
        echo "Can't talk to Tx"
        exit 1
    fi
}

POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"
case $key in
    -d)
        set -x	
        shift
    ;;
    -f)
        freq_kHz="$2"	
        shift
        shift
    ;;
    -g)
        gain="$2"	
        shift
        shift
    ;;
    -o)
        model="$2"	
        shift
        shift
    ;;
    -m)
        mode="$2"	
        shift
        shift
    ;;
    -p)
        port="$2"	
        shift
        shift
    ;;
    -t)
        tx_only=1	
        shift
    ;;
    -s)
        serialPort="$2"
        shift
        shift
    ;;
    -h)
        print_help	
    ;;
    *)
    POSITIONAL+=("$1") # save it in an array for later
    shift
    ;;
esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

speechfile="$1"
if [ ! -f $speechfile ]; then
    echo "Can't find ${speechfile}!"
    exit 1
fi

if [ $tx_only -eq 0 ]; then
    if [ $# -lt 1 ]; then
        print_help
    fi
    kiwi_url="$2"
    echo $kiwi_url
fi

# create Tx file ------------------------
# create compressed analog
speech_comp=$(mktemp)
speech_freedv=$(mktemp)
analog_compressor $speechfile $speech_comp $gain
# create modulated FreeDV
freedv_tx $mode $speechfile $speech_freedv
cat $speech_comp $speech_freedv > tx.raw
sox -t .s16 -r 8000 -c 1 tx.raw tx.wav

usb_lsb=$(python3 -c "print('usb') if ${freq_kHz} >= 10000 else print('lsb')")

# kick off KiwiSDR ----------------------------

if [ $tx_only -eq 0 ]; then
    echo -n "waiting for KiwiSDR "
    # start recording from remote kiwisdr
    kiwi_stdout=$(mktemp)
    kiwirecorder.py -s $kiwi_url -p ${port} -f $freq_kHz -m ${usb_lsb} -r 8000 --filename=rx --time-limit=300 >$kiwi_stdout &
    kiwi_pid=$!

    # wait for kiwi to start recording
    timeout_counter=0
    until grep -q -i 'Block: ' $kiwi_stdout
    do
        timeout_counter=$((timeout_counter+1))
        if [ $timeout_counter -eq 10 ]; then
            echo "can't connect to ${kiwi_url}"
            exit 1
        fi
        echo -n "."
        sleep 1
    done
    echo
fi

# transmit using local SSB radio
echo "Tx data signal"
freq_Hz=$((freq_kHz*1000))
usb_lsb_upper=$(echo ${usb_lsb} | awk '{print toupper($0)}')
run_rigctl "\\set_mode PKT${usb_lsb_upper} 0" $model
run_rigctl "\\set_freq ${freq_Hz}" $model
run_rigctl "\\set_ptt 1" $model
aplay --device="plughw:CARD=CODEC,DEV=0" -f S16_LE tx.raw 2>/dev/null
run_rigctl "\\set_ptt 0" $model

if [ $tx_only -eq 0 ]; then
    sleep 2
    echo "Stopping KiwiSDR"
    kill ${kiwi_pid}
    wait ${kiwi_pid} 2>/dev/null

    echo "Process receiver sample"
    # generate spectrogram
    echo "pkg load signal; warning('off', 'all'); \
          s=load_raw('rx.wav'); \
          plot_specgram(s, 8000, 200, 3000); print('spec.jpg', '-djpg'); \
          quit" | octave-cli -p ${CODEC2}/octave -qf > /dev/null
    # attempt to decode
    freedv_rx ${mode} rx.wav - | sox -t .s16 -r 8000 -c 1 - rx_freedv.wav
    # time domain plot of output speech
    echo "pkg load signal; warning('off', 'all'); \
          s=load_raw('rx_freedv.wav'); \
          plot(s); print('time.jpg', '-djpg'); \
          quit" | octave-cli -p ${CODEC2}/octave -qf > /dev/null
fi

