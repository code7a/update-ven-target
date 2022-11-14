#!/bin/bash
#
#Update VEN target PCE FQDN
version="0.0.2"
#
#Licensed under the Apache License, Version 2.0 (the "License"); you may not
#use this file except in compliance with the License. You may obtain a copy of
#the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
#Unless required by applicable law or agreed to in writing, software
#distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#License for the specific language governing permissions and limitations under
#the License.
#

usage(){
    cat << EOF
update-ven-target.sh - updates VEN target PCE FQDN
https://github.com/code7a/update-ven-target

jq is required to parse results and the binary is include in this build.
https://stedolan.github.io/jq/

usage: ./update-ven-target.sh [options]

options:
    -g, --get-report                returns report on vens active and target PCE FQDNs
    -u, --update-targets            updates VEN target PCE FQDN
        by-round-robin          default, iterates through each VEN and active PCE members and evenly updates
        by-app-label            iterates through each VEN application label and active PCE members
        by-loc-label            iterates through each VEN location label and active PCE members
    -x, --exclude-fqdn <FQDN>       exclude PCE FQDN or FQDNs by a comma separated string of FQDNs
    -i, --include-fqdn <FQDN>       only include PCE FQDN or FQDNs by a comma separated string of FQDNs
    -l, --include-label <int>       only update VENs with a specifc label href integer
    -v, --version                   returns version
    -h, --help                      returns help message

examples:
    ./update-ven-target.sh --get-report
    ./update-ven-target.sh --update-targets
    ./update-ven-target.sh --update-targets by-app-label --exclude-fqdn us.pce.local
    ./update-ven-target.sh --update-targets by-loc-label --exclude-fqdn us.pce.local,eu.pce.local
    ./update-ven-target.sh --update-targets --include-label 201
    ./update-ven-target.sh -u -x us.pce.local -l 201
    ./update-ven-target.sh -u -i us.pce.local
    ./update-ven-target.sh --version
    ./update-ven-target.sh --help
EOF
}

get_config_yml(){
    source .pce_config.yml || get_vars
}

get_vars(){
    read -p "Enter PCE domain: " ILO_PCE_DOMAIN
    read -p "Enter PCE port: " ILO_PCE_PORT
    read -p "Enter PCE organization ID: " ILO_PCE_ORG_ID
    read -p "Enter PCE API username: " ILO_PCE_API_USERNAME
    echo -n "Enter PCE API secret: " && read -s ILO_PCE_API_SECRET && echo ""
    cat << EOF > .pce_config.yml
export ILO_PCE_DOMAIN=$ILO_PCE_DOMAIN
export ILO_PCE_PORT=$ILO_PCE_PORT
export ILO_PCE_ORG_ID=$ILO_PCE_ORG_ID
export ILO_PCE_API_USERNAME=$ILO_PCE_API_USERNAME
export ILO_PCE_API_SECRET=$ILO_PCE_API_SECRET
EOF
}

get_jq_version(){
    jq_version=$(jq --version)
    if [ $(echo $?) -ne 0 ]; then
        echo "jq application not found. jq is a commandline JSON processor and is used to process and filter JSON inputs."
        echo "https://stedolan.github.io/jq/"
        echo "Script will attempt to copy the included jq binary to /usr/bin/"
        cp ./jq /usr/bin/ || cp illumio-vmware-nsx-sync/jq /usr/bin/ || echo -e "Please install jq, i.e. yum install jq\nor manually copy the included binary to /usr/bin/, i.e. cp ./jq /usr/bin/" && exit 1
    fi
}

get_version(){
    echo "update-ven-target v"$version
}

get_fqdns(){
    get_config_yml
    fqdns=($(curl -k -s https://$ILO_PCE_API_USERNAME:$ILO_PCE_API_SECRET@$ILO_PCE_DOMAIN:$ILO_PCE_PORT/api/v2/health | jq -r .[].fqdn))
    if [ "$?" -ne 0 ]; then
        echo "ERROR: web request error. Please update .pce_config.yml"
        get_vars
    elif [ "$fqdns" == "" ]; then
        echo "ERROR: web response empty. Please update .pce_config.yml"
        get_vars
    fi
    if [ -n "$EXCLUDE_FQDN" ] && [ -n "$INCLUDE_FQDN" ]; then
        echo "ERROR: only use an inclusive or exclusive fqdn parameter filter"
        exit 1
    elif [ -n "$EXCLUDE_FQDN" ]; then
        exclude_count=0
        unset include_fqdns
        include_fqdns=()
        for fqdn in "${fqdns[@]}"; do
            if grep -q "$fqdn" <<< "$EXCLUDE_FQDN"; then
                ((exclude_count++))
                continue
            fi
            include_fqdns+=($fqdn)
        done
        if [[ "$exclude_count" -eq 0 ]]; then
            echo "ERROR: exclude fqdn argument is not a valid FQDN"
            exit 1
        fi
        unset fqdns
        fqdns=()
        fqdns=(${include_fqdns[@]})
    elif [ -n "$INCLUDE_FQDN" ]; then
        include_count=0
        unset include_fqdns
        include_fqdns=()
        for fqdn in "${fqdns[@]}"; do
            if grep -q "$fqdn" <<< "$INCLUDE_FQDN"; then
                include_fqdns+=($fqdn)
                ((include_count++))
            fi
        done
        if [[ "$include_count" -eq 0 ]]; then
            echo "ERROR: include fqdn argument is not a valid FQDN"
            exit 1
        fi
        unset fqdns
        fqdns=()
        fqdns=(${include_fqdns[@]})
    fi
}

print_fqdns(){
    echo "getting fqdns..."
    get_fqdns
    echo "" && echo "PCE Cluster returned ${#fqdns[@]} fqdns: ${fqdns[@]}"
}

get_vens(){
    #check if valid label href integer
    if [ -v INCLUDE_LABEL_INT ]; then
        label_response=$(curl -k https://$ILO_PCE_API_USERNAME:$ILO_PCE_API_SECRET@$ILO_PCE_DOMAIN:$ILO_PCE_PORT/api/v2/orgs/1/labels/$INCLUDE_LABEL_INT -o /dev/null -s -w '%{http_code}\n')
        if [[ $label_response -ne 200 ]]; then
            echo "ERROR: invalid label href integer"
            exit 1
        fi
    fi
    vens=$(curl -k -s "https://$ILO_PCE_API_USERNAME:$ILO_PCE_API_SECRET@$ILO_PCE_DOMAIN:$ILO_PCE_PORT/api/v2/orgs/1/vens?max_results=200000&labels=%5B%5B${INCLUDE_LABEL}%5D%5D")
    vens_hrefs=($(echo $vens | jq -r .[].href))
    vens_unique_labels_hrefs=($(echo $vens |jq -r .[].labels[].href | sort | uniq))
    vens_labels_hrefs=($(echo $vens |jq -r .[].labels[].href | sort))
}

print_vens(){
    get_vens
    echo -n "vens found: "
    echo ${#vens_hrefs[@]}
}

get_vens_fqdns(){
    get_fqdns
    print_vens
    echo "ven count by active fqdn:"
    echo $vens | jq -r .[].active_pce_fqdn | sort | uniq -c
    echo "ven count by target fqdn:"
    echo $vens | jq -r .[].target_pce_fqdn | sort | uniq -c
}

update_ven_target_fqdn(){
    get_fqdns
    get_vens
    fqdn_count=0
    echo "updating targets..."
    for ven_href in "${vens_hrefs[@]}"; do
        curl -X PUT -k https://$ILO_PCE_API_USERNAME:$ILO_PCE_API_SECRET@$ILO_PCE_DOMAIN:$ILO_PCE_PORT/api/v2${ven_href} -H "content-type: application/json" --data '{"target_pce_fqdn": "'${fqdns[$fqdn_count]}'"}'
        ((fqdn_count=fqdn_count+1))
        if (( $fqdn_count == ${#fqdns[@]} )); then
            fqdn_count=0
        fi
    done
    get_vens_fqdns
}

get_unique_vens_labels(){
    get_vens
    roles=()
    apps=()
    locs=()
    envs=()
    for label_href in "${vens_unique_labels_hrefs[@]}"; do
        #note: ?max_results parameter not set, may hit limit
        label_key=$(curl -s -k https://$ILO_PCE_API_USERNAME:$ILO_PCE_API_SECRET@$ILO_PCE_DOMAIN:$ILO_PCE_PORT/api/v2{$label_href} | jq -r .key)
        if [ "$label_key" == "role" ]; then
            roles+=($label_href)
        elif [ "$label_key" == "app" ]; then
            apps+=($label_href)
        elif [ "$label_key" == "loc" ]; then
            locs+=($label_href)
        elif [ "$label_key" == "env" ]; then
            envs+=($label_href)
        fi
    done
    #sort roles by count decreasing
    role_labels_json=""
    role_labels_json+="["
    for app in "${roles[@]}"; do
        count=$(echo $vens | jq -r '.[]|select(.labels[].href=="'$app'")|.href' | wc -l)
        role_labels_json+='{"href":"'$app'","count":'$count'},'
    done
    role_labels_json=${role_labels_json::-1}
    role_labels_json+="]"
    role_labels_json=$(echo $role_labels_json | jq '. | sort_by(.count) | reverse')
    roles=($(echo $role_labels_json | jq -r .[].href))
    #sort apps by count decreasing
    app_labels_json=""
    app_labels_json+="["
    for app in "${apps[@]}"; do
        count=$(echo $vens | jq -r '.[]|select(.labels[].href=="'$app'")|.href' | wc -l)
        app_labels_json+='{"href":"'$app'","count":'$count'},'
    done
    app_labels_json=${app_labels_json::-1}
    app_labels_json+="]"
    app_labels_json=$(echo $app_labels_json | jq '. | sort_by(.count) | reverse')
    apps=($(echo $app_labels_json | jq -r .[].href))
    #sort locations by count decreasing
    loc_labels_json=""
    loc_labels_json+="["
    for loc in "${locs[@]}"; do
        count=$(echo $vens | jq -r '.[]|select(.labels[].href=="'$loc'")|.href' | wc -l)
        loc_labels_json+='{"href":"'$loc'","count":'$count'},'
    done
    loc_labels_json=${loc_labels_json::-1}
    loc_labels_json+="]"
    loc_labels_json=$(echo $loc_labels_json | jq '. | sort_by(.count) | reverse')
    locs=($(echo $loc_labels_json | jq -r .[].href))
    #sort environments by count decreasing
    env_labels_json=""
    env_labels_json+="["
    for env in "${envs[@]}"; do
        count=$(echo $vens | jq -r '.[]|select(.labels[].href=="'$env'")|.href' | wc -l)
        env_labels_json+='{"href":"'$env'","count":'$count'},'
    done
    env_labels_json=${env_labels_json::-1}
    env_labels_json+="]"
    env_labels_json=$(echo $env_labels_json | jq '. | sort_by(.count) | reverse')
    envs=($(echo $env_labels_json | jq -r .[].href))
}

print_unique_vens_labels(){
    get_unique_vens_labels
    echo "unique vens role labels:"
    echo ${roles[@]}
    echo "unique vens application labels:"
    echo ${apps[@]}
    echo "unique vens location labels:"
    echo ${locs[@]}
    echo "unique vens environment labels:"
    echo ${envs[@]}
}

update_ven_target_fqdn_by_app(){
    get_fqdns
    get_unique_vens_labels
    fqdn_count=0
    echo "updating targets..."
    for app in "${apps[@]}"; do
        select_vens_hrefs=($(echo $vens | jq -r '.[]|select(.labels[].href=="'$app'")|.href'))
        for ven_href in "${select_vens_hrefs[@]}"; do
            curl -X PUT -k https://$ILO_PCE_API_USERNAME:$ILO_PCE_API_SECRET@$ILO_PCE_DOMAIN:$ILO_PCE_PORT/api/v2${ven_href} -H "content-type: application/json" --data '{"target_pce_fqdn": "'${fqdns[$fqdn_count]}'"}'
        done
        ((fqdn_count++))
        if (( $fqdn_count == ${#fqdns[@]} )); then
            fqdn_count=0
        fi
    done
    get_vens_fqdns
}

update_ven_target_fqdn_by_loc(){
    get_fqdns
    get_unique_vens_labels
    fqdn_count=0
    echo "updating targets..."
    for loc in "${locs[@]}"; do
        select_vens_hrefs=($(echo $vens | jq -r '.[]|select(.labels[].href=="'$loc'")|.href'))
        for ven_href in "${select_vens_hrefs[@]}"; do
            curl -X PUT -k https://$ILO_PCE_API_USERNAME:$ILO_PCE_API_SECRET@$ILO_PCE_DOMAIN:$ILO_PCE_PORT/api/v2${ven_href} -H "content-type: application/json" --data '{"target_pce_fqdn": "'${fqdns[$fqdn_count]}'"}'
        done
        ((fqdn_count++))
        if (( $fqdn_count == ${#fqdns[@]} )); then
            fqdn_count=0
        fi
    done
    get_vens_fqdns
}

get_jq_version

UPDATE=
EXCLUDE_FQDN=
INCLUDE_FQDN=
INCLUDE_LABEL=

while true
do
    if [ "$1" == "" ]; then
        break
    fi
    case $1 in
        -h|--help)
            usage
            exit 1
            ;;
        -g|--get-report)
            print_fqdns
            get_vens_fqdns
            exit 0
            ;;
        -u|--update-targets)
            if [ "$2" == "" ] || [[ "$2" == -* ]]; then
                UPDATE=update_ven_target_fqdn
            elif [ "$2" == "by-round-robin" ]; then
                UPDATE=update_ven_target_fqdn
                shift
            elif [ "$2" == "by-app-label" ]; then
                UPDATE=update_ven_target_fqdn_by_app
                shift
            elif [ "$2" == "by-loc-label" ]; then
                UPDATE=update_ven_target_fqdn_by_loc
                shift
            else
                exit 1
            fi
            ;;
        -x|--exclude-fqdn)
            if [ "$2" == "" ] || [[ "$2" == -* ]]; then
                echo "ERROR: exclude fqdn argument requires a parameter of an fqdn or comma separated string of fqdns"
                exit 1
            fi
            EXCLUDE_FQDN=$2
            shift
            ;;
        -i|--include-fqdn)
            if [ "$2" == "" ] || [[ "$2" == -* ]]; then
                echo "ERROR: include fqdn argument requires a parameter of an fqdn or comma separated string of fqdns"
                exit 1
            fi
            INCLUDE_FQDN=$2
            shift
            ;;
        -l|--include-label)
            if [ "$2" == "" ] || [[ "$2" == -* ]]; then
                echo "ERROR: include label href integer argument required"
                exit 1
            elif ! [[ "$2" =~ ^[[:digit:]]+$ ]]; then
                echo "ERROR: include label href integer argument type, only enter integer"
                exit 1
            fi
            INCLUDE_LABEL_INT=$2
            INCLUDE_LABEL="%22%2Forgs%2F$ILO_PCE_ORG_ID%2Flabels%2F$INCLUDE_LABEL_INT%22"
            shift
            ;;
        -v|--version)
            get_version
            exit 0
            ;;
        -*)
            echo -e "\n$0: ERROR: Unknown option: $1" >&2
            usage
            exit 1
            ;;
        *)
            echo -e "\n$0: ERROR: Unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
    shift
done

$UPDATE

exit 0
