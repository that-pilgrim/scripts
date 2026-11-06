#!/bin/bash

# Enhanced Server Connection Monitor
# Compatible with Debian 10 Buster and other Linux distributions
# 
# Usage:
#   ./connections.sh                # Show current connections
#   ./connections.sh --days N       # Show historical connections
#   ./connections.sh --blocklist    # Generate IP blocklist
#   ./connections.sh --portscan     # Scan for open ports
#   ./connections.sh --whois        # Show whois data for top connections

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DAYS=0
BLOCKLIST=false
INSTALL_MODE=false
PORT_SCAN=false
WHOIS_INFO=false

# Process command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --days)
      DAYS="$2"
      shift 2
      ;;
    --blocklist)
      BLOCKLIST=true
      shift
      ;;
    --install)
      INSTALL_MODE=true
      shift
      ;;
    --portscan)
      PORT_SCAN=true
      shift
      ;;
    --whois)
      WHOIS_INFO=true
      shift
      ;;
    --help)
      echo "Usage: ./connections.sh [OPTIONS]"
      echo "Options:"
      echo "  --days N       Show connections for past N days"
      echo "  --blocklist    Generate IP blocklist recommendations"
      echo "  --install      Check and install required tools"
      echo "  --portscan     Scan for open ports on the server"
      echo "  --whois        Show whois data for top connecting IPs"
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      echo "Usage: ./connections.sh [--days N] [--blocklist] [--install] [--portscan] [--whois]"
      exit 1
      ;;
  esac
done

# Check and setup sudo if needed
if [ "$EUID" -ne 0 ]; then
  echo -e "${YELLOW}Some operations require root privileges.${NC}"
  echo -e "Consider running with sudo for full details."
  USE_SUDO="sudo"
else
  USE_SUDO=""
fi

# Check for required tools
check_tools() {
  echo -e "\n${BLUE}=== Checking for required tools ===${NC}"
  
  TOOL_LIST="ss lsof netstat tcpdump iptables"
  
  if [ "$PORT_SCAN" = true ]; then
    TOOL_LIST="$TOOL_LIST nmap"
  fi
  
  if [ "$WHOIS_INFO" = true ]; then
    TOOL_LIST="$TOOL_LIST whois"
  fi
  
  MISSING_TOOLS=""
  
  for tool in $TOOL_LIST; do
    if command -v $tool &> /dev/null; then
      echo -e "${GREEN}$tool is installed${NC}"
    else
      echo -e "${YELLOW}$tool is not installed${NC}"
      MISSING_TOOLS="$MISSING_TOOLS $tool"
    fi
  done
  
  if [ ! -z "$MISSING_TOOLS" ]; then
    if [ "$INSTALL_MODE" = true ]; then
      echo -e "\n${BLUE}Installing missing tools...${NC}"
      if command -v apt &> /dev/null; then
        $USE_SUDO apt update
        for tool in $MISSING_TOOLS; do
          case $tool in
            ss)
              $USE_SUDO apt install -y iproute2
              ;;
            netstat)
              $USE_SUDO apt install -y net-tools
              ;;
            *)
              $USE_SUDO apt install -y $tool
              ;;
          esac
        done
      elif command -v yum &> /dev/null; then
        for tool in $MISSING_TOOLS; do
          case $tool in
            ss)
              $USE_SUDO yum install -y iproute
              ;;
            netstat)
              $USE_SUDO yum install -y net-tools
              ;;
            *)
              $USE_SUDO yum install -y $tool
              ;;
          esac
        done
      else
        echo -e "${RED}Unsupported package manager. Please install manually:${NC}"
        echo "$MISSING_TOOLS"
      fi
    else
      echo -e "\n${YELLOW}Missing tools. Run with --install to install them:${NC}"
      echo "$MISSING_TOOLS"
      echo -e "Command: ${GREEN}$0 --install${NC}"
      
      # Check if any required tools for specific functions are missing
      if [[ "$PORT_SCAN" = true && "$MISSING_TOOLS" == *"nmap"* ]]; then
        echo -e "${RED}Port scanning requires nmap. Please install it first.${NC}"
        PORT_SCAN=false
      fi
      
      if [[ "$WHOIS_INFO" = true && "$MISSING_TOOLS" == *"whois"* ]]; then
        echo -e "${RED}WHOIS lookups require whois. Please install it first.${NC}"
        WHOIS_INFO=false
      fi
    fi
  fi
}

# Show active connections (fixed version)
show_connections() {
  echo -e "\n${BLUE}=== ACTIVE CONNECTIONS ===${NC}"
  echo -e "${GREEN}IP Address           Connection Type    Count${NC}"
  echo -e "${GREEN}----------------------------------------------${NC}"
  
  # Create temp file for IP list
  TOP_IPS_FILE=$(mktemp)
  
  # Try ss first
  if command -v ss &> /dev/null; then
    # Get established connections with clean output
    $USE_SUDO ss -tn | grep ESTAB | awk '{print $5}' | cut -d: -f1 | grep -v -E '^\[|^$' | sort | uniq -c | sort -nr | head -10 > "$TOP_IPS_FILE"
    
    # Process each IP
    while read count ip; do
      conn_type="Other"
      # Try to determine the connection type
      if $USE_SUDO ss -tn | grep ESTAB | grep "$ip" | grep -q ":22"; then
        conn_type="SSH"
      elif $USE_SUDO ss -tn | grep ESTAB | grep "$ip" | grep -q -E ":80|:443"; then
        conn_type="HTTP(S)"
      elif $USE_SUDO ss -tn | grep ESTAB | grep "$ip" | grep -q ":3306"; then
        conn_type="MySQL"
      fi
      printf "%-20s %-18s %d\n" "$ip" "$conn_type" "$count"
    done < "$TOP_IPS_FILE"
  # Fallback to netstat
  elif command -v netstat &> /dev/null; then
    $USE_SUDO netstat -tn | grep ESTAB | awk '{print $5}' | cut -d: -f1 | grep -v -E '^\[|^$' | sort | uniq -c | sort -nr | head -10 > "$TOP_IPS_FILE"
    
    # Process each IP
    while read count ip; do
      conn_type="Other"
      # Try to determine the connection type
      if $USE_SUDO netstat -tn | grep ESTAB | grep "$ip" | grep -q ":22"; then
        conn_type="SSH"
      elif $USE_SUDO netstat -tn | grep ESTAB | grep "$ip" | grep -q -E ":80|:443"; then
        conn_type="HTTP(S)"
      elif $USE_SUDO netstat -tn | grep ESTAB | grep "$ip" | grep -q ":3306"; then
        conn_type="MySQL"
      fi
      printf "%-20s %-18s %d\n" "$ip" "$conn_type" "$count"
    done < "$TOP_IPS_FILE"
  else
    echo -e "${RED}Neither ss nor netstat is available.${NC}"
  fi
  
  # Save top IPs file for whois lookups
  if [ "$WHOIS_INFO" = true ]; then
    WHOIS_INPUT_FILE="$TOP_IPS_FILE"
  else
    rm -f "$TOP_IPS_FILE"
  fi
}

# Show detailed connection info (fixed localhost display)
show_process_details() {
  if command -v lsof &> /dev/null; then
    echo -e "\n${BLUE}=== CONNECTION DETAILS ===${NC}"
    echo -e "${GREEN}Command         PID       User      IP Address${NC}"
    echo -e "${GREEN}------------------------------------------------------${NC}"
    
    $USE_SUDO lsof -i -nP | grep -i estab | head -10 | while read line; do
      command=$(echo "$line" | awk '{print $1}')
      pid=$(echo "$line" | awk '{print $2}')
      user=$(echo "$line" | awk '{print $3}')
      ip_info=$(echo "$line" | awk '{print $9}')
      
      # Check if it's a localhost address in brackets
      if [[ "$ip_info" == *"]->"* ]] || [[ "$ip_info" == *"127.0.0.1"* ]]; then
        remote_ip="localhost"
      else
        # Regular external IP
        remote_ip=$(echo "$ip_info" | sed -E 's/.*->([^:]+):.*/\1/')
      fi
      
      printf "%-15s %-9s %-9s %s\n" "$command" "$pid" "$user" "$remote_ip"
    done
  fi
}

# Show listening services
show_listening_services() {
  echo -e "\n${BLUE}=== LISTENING SERVICES ===${NC}"
  echo -e "${GREEN}Port     Protocol  Service         Process${NC}"
  echo -e "${GREEN}--------------------------------------------------${NC}"
  
  # Create temporary file for port list
  PORT_LIST_FILE=$(mktemp)
  
  if command -v ss &> /dev/null; then
    # Extract all listening ports
    $USE_SUDO ss -tulnp | grep LISTEN | sed -n 's/.*[^0-9]\([0-9]\+\).*/\1/p' | sort -un > "$PORT_LIST_FILE"
    
    # Process each port
    while read port; do
      line=$($USE_SUDO ss -tulnp | grep -w "$port" | grep LISTEN | head -1)
      
      # Extract protocol
      if echo "$line" | grep -q "^tcp"; then
        proto="tcp"
      elif echo "$line" | grep -q "^udp"; then
        proto="udp"
      else
        proto="unknown"
      fi
      
      # Extract process name
      process="Unknown"
      if echo "$line" | grep -q "users"; then
        process=$(echo "$line" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p')
        if [ -z "$process" ]; then
          process="Unknown"
        fi
      fi
      
      # Determine service
      service="Unknown"
      case $port in
        22) service="SSH" ;;
        80) service="HTTP" ;;
        443) service="HTTPS" ;;
        21) service="FTP" ;;
        25|587|465) service="SMTP" ;;
        53) service="DNS" ;;
        3306) service="MySQL" ;;
        5432) service="PostgreSQL" ;;
        8080) service="Alt-HTTP" ;;
        *) service="Other" ;;
      esac
      
      printf "%-8s %-9s %-15s %s\n" "$port" "$proto" "$service" "$process"
    done < "$PORT_LIST_FILE"
  elif command -v netstat &> /dev/null; then
    # Extract all listening ports
    $USE_SUDO netstat -tulnp | grep LISTEN | sed -n 's/.*[^0-9]\([0-9]\+\).*/\1/p' | sort -un > "$PORT_LIST_FILE"
    
    # Process each port
    while read port; do
      line=$($USE_SUDO netstat -tulnp | grep -w "$port" | grep LISTEN | head -1)
      
      # Extract protocol and process
      proto=$(echo "$line" | awk '{print $1}')
      process=$(echo "$line" | awk '{print $NF}' | cut -d/ -f2)
      
      # Determine service
      service="Unknown"
      case $port in
        22) service="SSH" ;;
        80) service="HTTP" ;;
        443) service="HTTPS" ;;
        21) service="FTP" ;;
        25|587|465) service="SMTP" ;;
        53) service="DNS" ;;
        3306) service="MySQL" ;;
        5432) service="PostgreSQL" ;;
        8080) service="Alt-HTTP" ;;
        *) service="Other" ;;
      esac
      
      printf "%-8s %-9s %-15s %s\n" "$port" "$proto" "$service" "$process"
    done < "$PORT_LIST_FILE"
  else
    echo -e "${RED}Neither ss nor netstat is available.${NC}"
  fi
  
  # Save port list for port scan comparison
  if [ "$PORT_SCAN" = true ]; then
    KNOWN_PORTS_FILE="$PORT_LIST_FILE"
  else
    rm -f "$PORT_LIST_FILE"
  fi
}

# Perform port scan to find all open ports
run_port_scan() {
  if [ "$PORT_SCAN" = false ]; then
    return
  fi
  
  if ! command -v nmap &> /dev/null; then
    echo -e "${RED}Port scanning requires nmap. Please install it first.${NC}"
    return
  fi
  
  echo -e "\n${BLUE}=== PORT SCAN RESULTS ===${NC}"
  echo -e "${YELLOW}Scanning for open ports...${NC}"
  
  # Scan localhost for open ports
  SCAN_RESULTS_FILE=$(mktemp)
  $USE_SUDO nmap -sT -p 1-65535 localhost | grep "^[0-9]" | awk '{print $1}' | cut -d/ -f1 | sort -n > "$SCAN_RESULTS_FILE"
  
  echo -e "${GREEN}Port     State    Service${NC}"
  echo -e "${GREEN}----------------------------${NC}"
  
  while read port; do
    # Determine service name
    service=$($USE_SUDO nmap -sT -p "$port" localhost | grep "^$port" | awk '{$1=""; $2=""; $3=""; print $0}' | sed 's/^[ \t]*//')
    if [ -z "$service" ]; then
      service="Unknown"
    fi
    
    # Check if port is in the known ports list
    if [ -f "$KNOWN_PORTS_FILE" ] && grep -q "^$port$" "$KNOWN_PORTS_FILE"; then
      state="Known"
    else
      state="UNKNOWN"
    fi
    
    # Print with highlighting for unknown ports
    if [ "$state" = "UNKNOWN" ]; then
      printf "${YELLOW}%-8s %-8s %s${NC}\n" "$port" "$state" "$service"
    else
      printf "%-8s %-8s %s\n" "$port" "$state" "$service"
    fi
  done < "$SCAN_RESULTS_FILE"
  
  # Show summary of unknown ports
  if [ -f "$KNOWN_PORTS_FILE" ]; then
    UNKNOWN_COUNT=$(comm -23 "$SCAN_RESULTS_FILE" "$KNOWN_PORTS_FILE" | wc -l)
    echo -e "\n${YELLOW}Found $UNKNOWN_COUNT possibly unexpected open ports.${NC}"
    
    if [ "$UNKNOWN_COUNT" -gt 0 ]; then
      echo -e "${RED}Unexpected open ports may indicate security issues.${NC}"
      echo -e "${YELLOW}Investigate any ports marked as UNKNOWN above.${NC}"
    fi
  fi
  
  # Clean up
  rm -f "$SCAN_RESULTS_FILE"
  [ -f "$KNOWN_PORTS_FILE" ] && rm -f "$KNOWN_PORTS_FILE"
}

# Show WHOIS information for top connecting IPs
show_whois_info() {
  if [ "$WHOIS_INFO" = false ]; then
    return
  fi
  
  if ! command -v whois &> /dev/null; then
    echo -e "${RED}WHOIS lookups require whois. Please install it first.${NC}"
    return
  fi
  
  if [ ! -f "$WHOIS_INPUT_FILE" ]; then
    echo -e "${RED}No IP addresses found for WHOIS lookup.${NC}"
    return
  fi
  
  echo -e "\n${BLUE}=== WHOIS INFORMATION FOR TOP CONNECTIONS ===${NC}"
  
  # Get top 5 IPs (non-local)
  TOP_IPS=$(cat "$WHOIS_INPUT_FILE" | awk '{print $2}' | grep -v -E '127\.0\.0\.1|192\.168\.|10\.' | head -5)
  
  for ip in $TOP_IPS; do
    echo -e "\n${YELLOW}WHOIS information for $ip:${NC}"
    echo -e "${GREEN}----------------------------------------${NC}"
    
    # Extract important WHOIS fields
    WHOIS_DATA=$(whois "$ip" 2>/dev/null)
    
    # Try to extract netblock info
    INETNUM=$(echo "$WHOIS_DATA" | grep -i -E "^inetnum:|^netrange:|^cidr" | head -1)
    NETNAME=$(echo "$WHOIS_DATA" | grep -i "^netname:" | head -1)
    ORG=$(echo "$WHOIS_DATA" | grep -i -E "^org:|^organization:|^owner" | head -1)
    COUNTRY=$(echo "$WHOIS_DATA" | grep -i "^country:" | head -1)
    ABUSE=$(echo "$WHOIS_DATA" | grep -i -E "^abuse|^e-mail" | head -1)
    
    # Print extracted fields
    [ ! -z "$INETNUM" ] && echo "$INETNUM"
    [ ! -z "$NETNAME" ] && echo "$NETNAME"
    [ ! -z "$ORG" ] && echo "$ORG"
    [ ! -z "$COUNTRY" ] && echo "$COUNTRY"
    [ ! -z "$ABUSE" ] && echo "$ABUSE"
    
    # If no structured data was found, print a summary
    if [ -z "$INETNUM$NETNAME$ORG$COUNTRY" ]; then
      echo "No structured data found for this IP."
    fi
  done
  
  # Clean up
  rm -f "$WHOIS_INPUT_FILE"
}

# Show login activity
show_login_activity() {
  if [ "$DAYS" -eq 0 ]; then
    return
  fi

  echo -e "\n${BLUE}=== LOGIN ACTIVITY (LAST $DAYS DAYS) ===${NC}"
  
  # Find auth log
  AUTH_LOG=""
  for log in /var/log/auth.log /var/log/secure; do
    if [ -f "$log" ]; then
      AUTH_LOG="$log"
      break
    fi
  done
  
  if [ -z "$AUTH_LOG" ]; then
    echo -e "${YELLOW}No authentication logs found.${NC}"
    return
  fi
  
  echo -e "${GREEN}Using log file: $AUTH_LOG${NC}"
  
  # Date range for filtering
  DATE_RANGE=$(date -d "$DAYS days ago" +"%b %e" | sed 's/  / /')
  echo -e "${GREEN}Looking for entries since: $DATE_RANGE${NC}"
  
  # Show successful logins
  echo -e "\n${GREEN}Successful Logins:${NC}"
  $USE_SUDO grep -i "sshd.*Accepted" "$AUTH_LOG" | grep -i "$DATE_RANGE" | awk '{print $(NF-3), $(NF-5)}' | sort | uniq -c | sort -nr | head -5 | while read count ip user; do
    printf "%-20s %-15s %-10s User: %s\n" "$ip" "SSH Login" "$count" "$user"
  done
  
  # Show failed logins
  echo -e "\n${YELLOW}Failed Login Attempts:${NC}"
  $USE_SUDO grep -i "Failed password" "$AUTH_LOG" | grep -i "$DATE_RANGE" | awk '{print $(NF-3)}' | sort | uniq -c | sort -nr | head -10 | while read count ip; do
    printf "%-20s %-15s %s attempts\n" "$ip" "Failed Login" "$count"
  done
}

# Generate IP blocklist
generate_blocklist() {
  if [ "$BLOCKLIST" = false ]; then
    return
  fi

  echo -e "\n${BLUE}=== IP BLOCKLIST RECOMMENDATIONS ===${NC}"
  
  # Find auth log
  AUTH_LOG=""
  for log in /var/log/auth.log /var/log/secure; do
    if [ -f "$log" ]; then
      AUTH_LOG="$log"
      break
    fi
  done
  
  if [ -z "$AUTH_LOG" ]; then
    echo -e "${YELLOW}No authentication logs found.${NC}"
    return
  fi
  
  BLOCKLIST_FILE="blocklist_$(date +%Y%m%d).txt"
  echo "# IP Blocklist - Generated $(date)" > "$BLOCKLIST_FILE"
  echo "# Format: IP address,Reason,Count" >> "$BLOCKLIST_FILE"
  
  # Find IPs with many failed login attempts
  echo -e "\n${YELLOW}IPs with multiple failed login attempts:${NC}"
  $USE_SUDO grep -i "Failed password" "$AUTH_LOG" | awk '{print $(NF-3)}' | sort | uniq -c | sort -nr | head -20 | while read count ip; do
    if [ "$count" -gt 5 ]; then
      echo "$ip,Failed login attempts,$count" >> "$BLOCKLIST_FILE"
      printf "%-20s %d attempts\n" "$ip" "$count"
    fi
  done
  
  echo -e "\n${GREEN}Blocklist saved to: $BLOCKLIST_FILE${NC}"
  
  # Show firewall integration instructions
  echo -e "\n${BLUE}Firewall Integration:${NC}"
  echo -e "${YELLOW}For iptables:${NC}"
  echo -e "  cat $BLOCKLIST_FILE | grep -v \"^#\" | cut -d',' -f1 | xargs -I{} iptables -A INPUT -s {} -j DROP"
  
  if command -v ufw &> /dev/null; then
    echo -e "\n${YELLOW}For UFW:${NC}"
    echo -e "  cat $BLOCKLIST_FILE | grep -v \"^#\" | cut -d',' -f1 | xargs -I{} ufw deny from {}"
  fi
}

# Traffic analysis
show_traffic() {
  if command -v tcpdump &> /dev/null; then
    echo -e "\n${BLUE}=== QUICK TRAFFIC ANALYSIS ===${NC}"
    echo -e "${YELLOW}Sampling network traffic...${NC}"
    
    # Create a temp file for the tcpdump output
    TCPDUMP_FILE=$(mktemp)
    
    # Sample traffic for a few seconds
    $USE_SUDO timeout 5 tcpdump -nn -c 100 -w "$TCPDUMP_FILE" 2>/dev/null
    
    # Process the captured traffic
    echo -e "\n${GREEN}Traffic Summary:${NC}"
    $USE_SUDO tcpdump -nn -r "$TCPDUMP_FILE" 2>/dev/null | grep -Eo "([0-9]{1,3}\.){3}[0-9]{1,3}" | sort | uniq -c | sort -nr | head -5 | while read count ip; do
      printf " %-16s %d packets\n" "$ip" "$count"
    done
    
    # Clean up
    rm -f "$TCPDUMP_FILE"
  fi
}

# Show system info
show_system_info() {
  HOSTNAME=$(hostname)
  KERNEL=$(uname -r)
  UPTIME=$(uptime -p 2>/dev/null || uptime | sed 's/.*up \([^,]*\),.*/\1/')
  
  echo -e "\n${BLUE}=====================================================${NC}"
  echo -e "${GREEN} SERVER CONNECTION MONITOR - $HOSTNAME${NC}"
  echo -e "${BLUE}=====================================================${NC}"
  echo -e "${YELLOW}Kernel: $KERNEL${NC}"
  echo -e "${YELLOW}Uptime: $UPTIME${NC}"
  echo -e "${YELLOW}Date:   $(date)${NC}"
  echo -e "${BLUE}=====================================================${NC}"
}

# Main execution
check_tools

# Skip other functions if in install mode
if [ "$INSTALL_MODE" = false ]; then
  show_system_info
  show_connections
  show_process_details
  show_listening_services
  run_port_scan
  show_whois_info
  show_login_activity
  show_traffic
  generate_blocklist
  
  echo -e "\n${GREEN}Script completed successfully.${NC}"
  echo -e "${BLUE}For more options, run: $0 --help${NC}"
fi
