#!/bin/bash

PROGNAME=`basename $0`

oid=''
ip4=1
ip6=2
ip4regex='^([1-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$'
ip6regex='^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|
([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::
(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))$'
retval=$?
exit_code=0
exit_str=""

declare -A bgp_states=(
	["6"]="ESTABLISHED"
	["5"]="OPENCONFIRM"
	["4"]="OPENSENT"
	["3"]="ACTIVE"
	["2"]="CONNECT"
	["1"]="IDLE"
)

declare -A bgp_to_exit_codes=(
	["6"]="0"
	["5"]="1"
	["4"]="1"
	["3"]="2"
	["2"]="2"
	["1"]="2"
)

state_string=("OK" "WARNING" "CRITICAL" "UNKNOWN")

print_usage() {
  echo "Usage:"
  echo "  $PROGNAME -h - show this message end exit "
  echo "  $PROGNAME -c <SNMP community name>"
  echo "  $PROGNAME -H <bgp server hostname/ip>"
  echo "  $PROGNAME -i <peer ip>"
  echo
  echo "Example:"
  echo "  $PROGNAME -H 91.236.251.6 -c pub4MRTG -i 91.236.251.3"
  echo
  exit 3
}

while getopts ":hH:c:i:p:" options; do
    case "${options}" in
        h)
            print_usage
            exit 3
            ;;
        H)
            hostname=${OPTARG}
            ;;
        c)
            community=${OPTARG}
            ;;
        i)
            peer_ip=${OPTARG}
            ;;
        p)
            prefixes=${OPTARG}
            ;;
    esac
done

shift $((OPTIND-1))

check_opt () {
    if [[ -z $1 ]]
    then
        echo "Please, specify $2"
        echo
        print_usage
        exit 3
    fi
}

check_opt "$hostname" "hostname or ip"
check_opt "$community" "SNMP community name"
check_opt "$peer_ip" "ip of checked peer"
check_opt "$prefixes" "amount of prefixes"

##function converts ipv6 address from shorten to full form using program "sipcalc", then convert to decimal dotted format
ip6_to_oid () {
    ##convert ip6 to full form
    ipv6_ext=$(sipcalc -a $peer_ip|grep "Expanded Address"|awk -F- '{print $2}')

    ##check if sipcalc is installed and works
    if [[ $retval -eq 127 ]]; then
	echo "Please, install sipcalc to use this plugin"
	exit 3
    elif [[ $retval -ne 0 ]]; then
	echo "Something went wrong when try to use sipcalc"
	exit 3
    fi

    ##remove colons from full form ip6
    ipv6_nocolons=`echo ${ipv6_ext//:}`

    ##convert ip6 to decimal dotted form
    ipv6_to_arr=()
    for (( i = 0; i < ${#ipv6_nocolons}/2; i=i+1 )); do
	ipv6_to_arr+=( "${ipv6_nocolons:i*2:2}" )
    done

    arr_to_oid=''
    for el in "${ipv6_to_arr[@]}"; do
	arr_to_oid+=`echo $(( 16#$el )).`
    done

    oid=$(echo $arr_to_oid|sed 's/.$//')
}

if [[ $peer_ip =~ $ip4regex ]]; then
    ipver="$ip4"
    oid="$peer_ip"
elif [[ $peer_ip =~ $ip6regex ]]; then
    ipver="$ip6"
    ip6_to_oid
else
    echo "Error: IP is not valid"
    exit 3
fi

index=$(snmpwalk -v2c -c $community $hostname SNMPv2-SMI::enterprises.2636.5.1.1.2.1.1.1.14 2> /dev/null|grep -w $oid|awk '{print $NF}')

pref_snmp=$(snmpwalk -v2c -c $community $hostname BGP4-V2-MIB-JUNIPER::jnxBgpM2PrefixInPrefixes.$index.$ipver.1 2> /dev/null|awk '{print $NF}')

bgp_state=$(snmpwalk -v2c -c $community $hostname 1.3.6.1.4.1.2636.5.1.1.2.1.1.1.2|grep -w $oid 2> /dev/null|awk '{print $NF}')

bgp_state_string="Returned BGP code is $bgp_state"

array_length=${#bgp_states[@]}

if [[ $bgp_state -eq 0 ]]; then
    exit_code=3
    exit_str="${state_string[$exit_code]}. No such bgp session with peer $peer_ip"
fi

if [[ $pref_snmp -ge $prefixes ]]; then
    exit_code=0
    exit_str="${state_string[$exit_code]}. Prefixes $pref_snmp on peer $peer_ip"
elif [[ $pref_snmp -lt $prefixes && $pref_snmp -gt 0 ]]; then
    exit_code=1
    exit_str="${state_string[$exit_code]}. Prefixes is $pref_snmp on peer $peer_ip (must be $prefixes)"
else
    for (( i=0; i<=$array_length; i++ ))
    do
        if [[ $bgp_state -eq $i && $bgp_state -ne 0 ]]; then
	    exit_str="${state_string[${bgp_to_exit_codes[$i]}]}. Peer $peer_ip is disconnected or none prefixes. BGP with peer $peer_ip has state ${bgp_states[$i]}. $bgp_state_string"
	    exit_code=${bgp_to_exit_codes[$i]}
	fi
    done
fi

echo "$exit_str"
exit "$exit_code"
