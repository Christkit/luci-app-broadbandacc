#!/bin/sh

# 声明全局变量
_switch=
_logging=
_bind_ip=
_publicnet_ip=
_publicnet_ip1=
_ip=
_ip1=
_http_cmd=
_http_cmd1=
_http_cmd2=
_time=

# 包含用于解析 JSON 格式返回值的函数
. /usr/share/libubox/jshn.sh

# 读取 UCI 设置相关函数2
uci_get_by_name(){
	local ret=$(uci -q get $NAME.$1.$2)
	echo -n ${ret:=$3}
}

uci_get_by_bool(){
	case $(uci_get_by_name "$1" "$2" "$3") in
		1|on|true|yes|enabled)echo -n 1;;
		*)echo -n 0;;
	esac
}

# 日志和状态栏输出。1 日志文件, 2 系统日志, 4 详细模式, 8 下行状态栏, 16 上行状态栏, 32 失败状态
_log() {
	local msg=$1 flag=$2 timestamp=$(date +'%Y/%m/%d %H:%M:%S')
	[ -z "$msg" ] && return
	[ -z "$flag" ] && flag=1

	[ $logging -eq 0 -a $(( $flag & 1 )) -ne 0 ] && flag=$(( $flag ^ 1 ))
	if [ $verbose -eq 0 -a $(( $flag & 4 )) -ne 0 ]; then
		[ $(( $flag & 1 )) -ne 0 ] && flag=$(( $flag ^ 1 ))
		[ $(( $flag & 2 )) -ne 0 ] && flag=$(( $flag ^ 2 ))
	fi
	if [ $down_acc -eq 0 -a $(( $flag & 8 )) -ne 0 ]; then
		flag=$(( $flag ^ 8 ))
		[ $up_acc -ne 0 ] && flag=$(( $flag | 16 ))
	fi
	if [ $up_acc -eq 0 -a $(( $flag & 16 )) -ne 0 ]; then
		flag=$(( $flag ^ 16 ))
		[ $down_acc -ne 0 ] && flag=$(( $flag | 8 ))
	fi

	[ $(( $flag & 1 )) -ne 0 ] && echo "$timestamp $msg" >> $LOGFILE 2> /dev/null
	[ $(( $flag & 2 )) -ne 0 ] && logger -p "daemon.info" -t "$NAME" "$msg"

	[ $(( $flag & 32 )) -eq 0 ] && local color="green" || local color="red"
	[ $(( $flag & 8 )) -ne 0 ] && echo -n "<font color=$color>$timestamp $msg</font>" > $down_state_file 2> /dev/null
	[ $(( $flag & 16 )) -ne 0 ] && echo -n "<font color=$color>$timestamp $msg</font>" > $up_state_file 2> /dev/null
}

# 清理日志
clean_log() {
	[ $logging -eq 1 -a -f "$LOGFILE" ] || return
	[ $(wc -l "$LOGFILE" | awk '{print $1}') -le 800 ] && return
	_log "清理日志文件"
	local logdata=$(tail -n 500 "$LOGFILE")
	echo "$logdata" > $LOGFILE 2> /dev/null
	unset logdata
}

# 获取接口IP地址
get_bind_ip() {
	network=$(uci get "broadband.general.network" 2> /dev/null)
	json_cleanup; json_load "$(ubus call network.interface.$network status 2> /dev/null)" >/dev/null 2>&1
	json_select "ipv4-address" >/dev/null 2>&1; json_select 1 >/dev/null 2>&1
	json_get_var _bind_ip "address"
	if [ -z "$_bind_ip" -o "$_bind_ip"x == "0.0.0.0"x ]; then
		_log "获取网络 $network IP地址失败，其他模式可能导致获取ip地址失败，加速效果可能受影响"
		return 1
	else
		_log "绑定IP地址: $_bind_ip" $(( 1 | 1 * 4 ))
		return 0
	fi
}

# 定义基本 HTTP 命令和参数
gen_http_cmd() {
	_http_cmd="https://tisu-api-v3.speedtest.cn/speedUp/query"
	_http_cmd1="https://api-v3.speedtest.cn/ip"
	_http_cmd2="https://tisu-api.speedtest.cn/api/v2/speedup/reopen"
	return 1
}
# json获取文件解析过程
# json_load "$(wget $_http_cmd -O query || cat query)"
# json_select "indexInfo"
# json_get_var _bind_ip "msg"

# 获取网络带宽信息
isp_bandwidth() {
	json_cleanup; json_load "$(wget-ssl -q -O - $_http_cmd2 --bind-address=$_bind_ip)"
	local _code
	json_get_var _code "code"
	
	if [ $_code -eq 10021 ]; then
	_log "请求接口异常，请重启插件再试"
	elif [ $_code -eq 10002 ]; then
	_log "操作过于频繁，接口提速已受理"
	elif [ $_code -eq 0 ]; then
	_log "服务接口连接正常"
	else
	_log "网络异常，请重启插件"
	fi
	
	json_cleanup; json_load "$(wget-ssl -q -O - $_http_cmd --bind-address=$_bind_ip)"
	#无法提速
	json_select "data"
	json_select "indexInfo"
	local _canSpeed
	json_get_var _canSpeed "canSpeed"
	
	if [ -z $_canSpeed ]; then
		 _log "网络不稳定"
		 rm -f "$down_state_file" "$up_state_file"
		 return 1
	elif [ $_canSpeed = 0 ]; then
		 _log "网络不支持"
		 rm -f "$down_state_file" "$up_state_file"
		 return 2
	else
	#提速成功
		json_select ..
		local _ip
		json_get_var _ip "ip"
		_log "出口IP地址: $_ip" $(( 1 | 1 * 4 ))
			
		local _dialAcct
		json_get_var _dialAcct "dialAcct"
		_log "宽带: $_dialAcct" $(( 1 | 1 * 4 ))
			
		local _updatedAt
		json_get_var _updatedAt "updatedAt"
		_log "提速开始时间: $_updatedAt" $(( 1 | 1 * 4 ))
			
		local _targetUpH
		json_get_var _targetUpH "targetUpH"			
		local _upHExpire
		json_get_var _upHExpire "upHExpire"
		_log "一类上行带宽$(expr $_targetUpH / 1024)M提速截至时间: $_upHExpire" $(( 1 | 1 * 4 ))

		local _targetUp100
		json_get_var _targetUp100 "targetUp100"			
		local _up100Expire
		json_get_var _up100Expire "up100Expire"
		_log "二类上行带宽$(expr $_targetUp100 / 1024)M提速截至时间: $_up100Expire" $(( 1 | 1 * 4 ))
			
		local _targetDown
		json_get_var _targetDown "targetDown"	
		local _downExpire
		json_get_var _downExpire "downExpire"
		_log "下行带宽$(expr $_targetDown / 1024)M提速截至时间: $_downExpire" $(( 1 | 1 * 4 ))
		#50
		local _upHExpireT
		json_get_var _upHExpireT "upHExpireT"
		#100
		local _up100ExpireT
		json_get_var _up100ExpireT "up100ExpireT"
		#500
		local _downExpireT
		json_get_var _downExpireT "downExpireT"
		#time
		local cur_sec=`date '+%s'`
		
	if [ $_up100ExpireT != "false" -a $_up100ExpireT -gt $cur_sec ]; then
		#二类上行提速
		local outmsg="二类上行提速成功，带宽已提升至 $(expr $_targetUp100 / 1024)M"; _log "$outmsg" $(( 1 | 2 * 8 ))
		[ $1 -eq 1 ] && down_acc=2 || up_acc=2
	elif [ $_upHExpireT != "false" -a $_upHExpireT -gt $cur_sec ]; then
		#一类上行提速
		local outmsg="一类上行提速成功，带宽已提升至 $(expr $_targetUpH / 1024)M"; _log "$outmsg" $(( 1 | 2 * 8 ))
		[ $1 -eq 1 ] && down_acc=2 || up_acc=2
	else
		local outmsg="上行未开通"; _log "$outmsg" $(( 1 | 2 * 8 | 32 ))
		[ $1 -eq 1 ] && down_acc=0 || up_acc=0
	fi
			
	if [ $_downExpireT != "false" -a $_downExpireT -gt $cur_sec ]; then
		#下行提速
		local outmsg="下行提速成功，带宽已提升至 $(expr $_targetDown / 1024)M"; _log "$outmsg" $(( 1 | 1 * 8 ))
		[ $1 -eq 1 ] && down_acc=2 || up_acc=2
	else
		local outmsg="下行未开通"; _log "$outmsg" $(( 1 | 1 * 8 | 32 ))
		[ $1 -eq 1 ] && down_acc=0 || up_acc=0
	fi
			
	fi 
	return 3
}

# 断网缓和策略
_start_Strategy() {
	local flag=$?
	if [ $flag = 1 ]; then
	     _log "无法提速，宽带助手开始网络检测 10s ... " 
	     sleep 10
	     isp_bandwidth
	elif [ $flag = 2 ]; then
	     _log "无法提速，宽带助手已停止。错误代码：2"
	     exit $flag
	fi
}

# 发送提速心跳信号
_keepalive() {
	#_publicnet_ip=x.x.x.x
	#_time=xx _time1
	#_interface
	#接口名称
	network=$(uci get "broadband.general.network" 2> /dev/null)

	#获取出口ip
	json_cleanup; json_load "$(wget-ssl -q -O - $_http_cmd1)"
	json_select "data"
	json_get_var _publicnet_ip "ip"
	#断网睡眠
	if [ -z $_publicnet_ip ]; then
	_log "网络断开！请检查接口是否断开"
	rm -f "$down_state_file" "$up_state_file"
	#长期断网心跳
	while : ; do
	     sleep 15
	     isp_bandwidth
	     if [ $? = 3 ]; then
	     _publicnet_ip1=$_publicnet_ip
	     break
	     fi
	done
	return 2
	fi
	
	#检测循环
	if [ $_interface = "pppoe" ]; then
	while true
        do
        _ip0=`ifconfig pppoe-$network | grep 'inet addr:' | grep -oE '([0-9]{1,3}.){3}.[0-9]{1,3}' | head -n 1`
	if [ -z $_ip0 ]; then
	_log "网络断开！请检查接口是否断开"
	rm -f "$down_state_file" "$up_state_file"
	break
	elif [ $_ip0 != $_ip1 ]; then
	get_bind_ip
	isp_bandwidth
	_ip1=$_ip0
	fi
        sleep 5        
        done
        return 1
	
	elif [ -n $_publicnet_ip -a -n $_publicnet_ip1 -a $_publicnet_ip != $_publicnet_ip1 ]; then
	get_bind_ip
	isp_bandwidth
	_publicnet_ip1=$_publicnet_ip
	return 1	
	elif [ -n $_publicnet_ip -a -n $_publicnet_ip1 -a $_publicnet_ip = $_publicnet_ip1 ]; then
	return 1

	else
	#ip1初始化
	_publicnet_ip1=$_publicnet_ip
	_ip0=`ifconfig pppoe-$network | grep 'inet addr:' | grep -oE '([0-9]{1,3}.){3}.[0-9]{1,3}' | head -n 1`
	_ip1=$_ip0
	json_cleanup; json_load "$(ubus call network.interface.$network status 2> /dev/null)" >/dev/null 2>&1
	#接口类型
	json_get_var _interface "proto"
	#接口连接时间
	#json_get_var _time "uptime"
	_keepalive
	fi
}

#7天自检
Weekly_cycle() {
	while : ; do
	sleep 7d && isp_bandwidth && _log "运行一周，自检提速修复..."
	done 
}

# 停止加速
broadband_logout() {
	local _interface=$(uci get "broadband.general.network" 2> /dev/null)
	#ifdown $_interface && ifup $_interface
	[ $down_acc -ne 0 ] && down_acc=1; [ $up_acc -ne 0 ] && up_acc=1
        return 1
}

# 中止信号处理
sigterm() {
	_log "trap sigterm, exit" $(( 1 | 4 ))
	broadband_logout
	rm -f "$down_state_file" "$up_state_file"
	exit 0
}

# 初始化
broadband_init() {
	[ "$1" != "--start" ] && return 1
	# 防止重复启动
	[ -f /var/lock/broadband.lock ] && return 1
	touch /var/lock/broadband.lock
	#系统准备，校准time
	sleep 5
	ntpd 2.cn.pool.ntp.org
	# 读取设置
	readonly NAME=broadband
	readonly LOGFILE=/var/log/${NAME}.log
	readonly down_state_file=/var/state/${NAME}_down_state
	readonly up_state_file=/var/state/${NAME}_up_state
	down_acc=$(uci_get_by_bool "general" "down_acc" 1)
	up_acc=$(uci_get_by_bool "general" "up_acc" 1)
	readonly logging=$(uci_get_by_bool "general" "logging" 0)
	readonly verbose=$(uci_get_by_bool "general" "verbose" 0)
	network=$(uci_get_by_name "general" "network" "wan")
	keepalive=10
	local enabled=$(uci_get_by_bool "general" "enabled" 0)
	([ $enabled -eq 0 ] || [ $down_acc -eq 0 -a $up_acc -eq 0 ] || [ -z "$network" ]) && return 2
	([ -z "$keepalive" -o -n "${keepalive//[0-9]/}" ] || [ $keepalive -lt 5 -o $keepalive -gt 60 ]) && keepalive=10
	readonly keepalive=$(( $keepalive ))

	[ $logging -eq 0 ] && cat /dev/null > $LOGFILE
	[ $logging -eq 1 ] && [ ! -d /var/log ] && mkdir -p /var/log
	[ -f "$LOGFILE" ] && _log "------------------------------"
	_log "宽带助手正在启动..."

	# 检查外部调用工具
	command -v wget-ssl >/dev/null || { _log "GNU Wget 未安装,尝试安装中...请重启插件"; opkg update; opkg install wget; return 3; }

	# 捕获中止信号
	trap 'sigterm' INT # Ctrl-C
	trap 'sigterm' QUIT # Ctrl-\
	trap 'sigterm' TERM # kill

	# 状态初始化
	clean_log
	[ -d /var/state ] || mkdir -p /var/state
	rm -f "$down_state_file" "$up_state_file"
	return 0
}

# 程序主体
broadband_main() {

		# 获取IP地址
		get_bind_ip
		gen_http_cmd
		
		# 获取带宽信息
		isp_bandwidth
		for i in 1 2 3; do
		    _start_Strategy
		done
		# 七天循环
		Weekly_cycle &
		# 提速保持
		while : ; do
			clean_log # 清理日志
			_keepalive
			sleep ${keepalive}m
		done
	broadband_logout
	rm -f "$down_state_file" "$up_state_file"
	_log "无法提速，宽带助手已停止。"
	return 6
}
# 程序入口
broadband_init "$@" && broadband_main
exit $?
