#!/usr/bin/env python3
"""
Hypervisor Network Scanner
Detects Hyper-V, Proxmox, and VMware hypervisors on the local subnet
Compatible with Windows and macOS
"""

# Auto-install requests if not available
try:
    import requests
except ImportError:
    import subprocess
    import sys
    print("Installing required 'requests' library...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "requests"])
    import requests

import socket
import threading
import ipaddress
import requests
import ssl
import time
import sys
from urllib3.exceptions import InsecureRequestWarning
from concurrent.futures import ThreadPoolExecutor, as_completed

# Suppress SSL warnings for self-signed certificates
requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

class HypervisorScanner:
    def __init__(self):
        self.found_hypervisors = []
        self.lock = threading.Lock()
        
    def get_local_network(self):
        """Get the local network subnet"""
        try:
            # Get local IP
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            local_ip = s.getsockname()[0]
            s.close()
            
            # Assume /24 subnet
            network = ipaddress.IPv4Network(f"{local_ip}/24", strict=False)
            return network
        except Exception as e:
            print(f"Error getting local network: {e}")
            return None
    
    def check_port(self, ip, port, timeout=2):
        """Check if a port is open on the given IP"""
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            result = sock.connect_ex((str(ip), port))
            sock.close()
            return result == 0
        except:
            return False
    
    def check_http_service(self, ip, port, ssl_enabled=False, timeout=5):
        """Check HTTP/HTTPS service and try to identify the hypervisor"""
        protocol = "https" if ssl_enabled else "http"
        url = f"{protocol}://{ip}:{port}"
        
        try:
            response = requests.get(
                url, 
                timeout=timeout, 
                verify=False,
                allow_redirects=True,
                headers={'User-Agent': 'HypervisorScanner/1.0'}
            )
            
            return {
                'status_code': response.status_code,
                'headers': dict(response.headers),
                'content': response.text[:2000],  # First 2KB
                'url': response.url
            }
        except requests.exceptions.RequestException:
            return None
    
    def identify_hypervisor(self, ip, port_results):
        """Identify the type of hypervisor based on open ports and HTTP responses"""
        hypervisor_info = {
            'ip': str(ip),
            'type': 'Unknown',
            'access_urls': [],
            'ports': []
        }
        
        # Check common hypervisor ports and services
        port_checks = [
            (22, False),    # SSH
            (80, False),    # HTTP
            (443, True),    # HTTPS
            (902, False),   # VMware Authentication
            (8006, True),   # Proxmox Web Interface
            (9443, True),   # VMware vCenter
            (5986, False),  # WinRM HTTPS (Hyper-V)
            (5985, False),  # WinRM HTTP (Hyper-V)
        ]
        
        open_ports = []
        http_responses = {}
        
        # Check which ports are open
        for port, use_ssl in port_checks:
            if self.check_port(ip, port):
                open_ports.append(port)
                hypervisor_info['ports'].append(port)
                
                # Try to get HTTP response for web interfaces
                if port in [80, 443, 8006, 9443]:
                    response = self.check_http_service(ip, port, use_ssl)
                    if response:
                        http_responses[port] = response
        
        # Analyze responses to identify hypervisor type
        for port, response in http_responses.items():
            content_lower = response['content'].lower()
            headers = response['headers']
            
            # Proxmox detection
            if (port == 8006 or 
                'proxmox' in content_lower or 
                'pve-manager' in content_lower or
                'server: pve-api-daemon' in str(headers).lower()):
                hypervisor_info['type'] = 'Proxmox VE'
                if port == 8006:
                    hypervisor_info['access_urls'].append(f"https://{ip}:8006")
                elif 443 in open_ports:
                    hypervisor_info['access_urls'].append(f"https://{ip}:443")
                break
            
            # VMware detection
            elif ('vmware' in content_lower or 
                  'vsphere' in content_lower or 
                  'vcenter' in content_lower or
                  port == 9443 or
                  'server: vmware' in str(headers).lower()):
                hypervisor_info['type'] = 'VMware vSphere/ESXi'
                if port == 9443:
                    hypervisor_info['access_urls'].append(f"https://{ip}:9443")
                elif 443 in open_ports:
                    hypervisor_info['access_urls'].append(f"https://{ip}:443")
                break
            
            # Hyper-V detection (through System Center or web interface)
            elif ('microsoft' in content_lower and 
                  ('hyper-v' in content_lower or 'scvmm' in content_lower)):
                hypervisor_info['type'] = 'Microsoft Hyper-V'
                if 443 in open_ports:
                    hypervisor_info['access_urls'].append(f"https://{ip}:443")
                break
        
        # Additional heuristics based on port combinations
        if hypervisor_info['type'] == 'Unknown':
            # VMware ESXi typically has 902 + 443
            if 902 in open_ports and 443 in open_ports:
                hypervisor_info['type'] = 'VMware ESXi (suspected)'
                hypervisor_info['access_urls'].append(f"https://{ip}:443")
            
            # Hyper-V with WinRM
            elif (5985 in open_ports or 5986 in open_ports) and 22 not in open_ports:
                hypervisor_info['type'] = 'Microsoft Hyper-V (suspected)'
                if 443 in open_ports:
                    hypervisor_info['access_urls'].append(f"https://{ip}:443")
            
            # Generic web interface
            elif 443 in open_ports or 80 in open_ports:
                hypervisor_info['type'] = 'Possible Hypervisor'
                if 443 in open_ports:
                    hypervisor_info['access_urls'].append(f"https://{ip}:443")
                elif 80 in open_ports:
                    hypervisor_info['access_urls'].append(f"http://{ip}:80")
        
        return hypervisor_info
    
    def scan_host(self, ip):
        """Scan a single host for hypervisor services"""
        try:
            # Quick ping-like check using socket
            if not self.check_port(ip, 22, timeout=1) and not self.check_port(ip, 80, timeout=1) and not self.check_port(ip, 443, timeout=1):
                return None
            
            hypervisor_info = self.identify_hypervisor(ip, {})
            
            # Only return if we found something interesting
            if (hypervisor_info['type'] != 'Unknown' or 
                len(hypervisor_info['ports']) >= 2 or
                any(port in hypervisor_info['ports'] for port in [8006, 9443, 902, 5985, 5986])):
                
                with self.lock:
                    self.found_hypervisors.append(hypervisor_info)
                    print(f"Found: {hypervisor_info['type']} at {ip}")
                
                return hypervisor_info
                
        except Exception as e:
            pass
        return None
    
    def scan_network(self, network, max_workers=50):
        """Scan the entire network for hypervisors"""
        print(f"Scanning network: {network}")
        print("This may take a few minutes...\n")
        
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            # Submit all scan jobs
            future_to_ip = {
                executor.submit(self.scan_host, ip): ip 
                for ip in network.hosts()
            }
            
            # Process completed scans
            for future in as_completed(future_to_ip):
                try:
                    future.result()
                except Exception as e:
                    pass
    
    def print_results(self):
        """Print the scan results"""
        print("\n" + "="*60)
        print("HYPERVISOR SCAN RESULTS")
        print("="*60)
        
        if not self.found_hypervisors:
            print("No hypervisors detected on the network.")
            return
        
        for i, hv in enumerate(self.found_hypervisors, 1):
            print(f"\n{i}. {hv['type']}")
            print(f"   IP Address: {hv['ip']}")
            print(f"   Open Ports: {', '.join(map(str, hv['ports']))}")
            
            if hv['access_urls']:
                print(f"   Access URLs:")
                for url in hv['access_urls']:
                    print(f"     - {url}")
            else:
                print(f"   Access URLs: None detected")
        
        print(f"\nTotal hypervisors found: {len(self.found_hypervisors)}")

def main():
    print("Hypervisor Network Scanner")
    print("Detecting Hyper-V, Proxmox, and VMware hypervisors...\n")
    
    scanner = HypervisorScanner()
    
    # Get local network
    network = scanner.get_local_network()
    if not network:
        print("Could not determine local network. Exiting.")
        sys.exit(1)
    
    start_time = time.time()
    
    try:
        # Scan the network
        scanner.scan_network(network)
        
        # Print results
        scanner.print_results()
        
        elapsed_time = time.time() - start_time
        print(f"\nScan completed in {elapsed_time:.2f} seconds")
        
    except KeyboardInterrupt:
        print("\n\nScan interrupted by user.")
        scanner.print_results()

if __name__ == "__main__":
    main()