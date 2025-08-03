# Internal DNS Health & Event Report

Run Date: 08/03/2025 21:25:03

## Domain Controller & DNS Server Health
### DC: DC1
* ✅ **DC1** resolved.
    - **FQDN:** DC1.Homelan.lab
    - **IPv4:** 10.0.0.4
    - **Operating System:** Windows Server 2025 Datacenter Evaluation
### DC: DC2
* ✅ **DC2** resolved.
    - **FQDN:** DC2.Homelan.lab
    - **IPv4:** 10.0.0.9
    - **Operating System:** Windows Server 2025 Datacenter Evaluation

## Mail Server Check
* ❌ No mail server detected (neither mail. A record nor MX records found).

## DNS Server Configuration Overview
### Server: DC1
* ✅ DNS service is running.
    - **Total Zones:** 7
    - **Forward Zones:**
    - _msdcs.Homelan.lab
    - Homelan.lab
    - TrustAnchors
    - **Reverse Zones:**
    - 0.0.10.in-addr.arpa
    - 0.in-addr.arpa
    - 127.in-addr.arpa
    - 255.in-addr.arpa
    - **Forwarders:** None
    - **Listening Interfaces:** 

### Server: DC2
* ✅ DNS service is running.
    - **Total Zones:** 7
    - **Forward Zones:**
    - _msdcs.Homelan.lab
    - Homelan.lab
    - TrustAnchors
    - **Reverse Zones:**
    - 0.0.10.in-addr.arpa
    - 0.in-addr.arpa
    - 127.in-addr.arpa
    - 255.in-addr.arpa
    - **Forwarders:** None
    - **Listening Interfaces:** 


## DNS Event Log Check (Last 24 Hours)
### Events from server: DC1
✅ No errors or warnings in the last 24 hours.
### Events from server: DC2
❌ Could not retrieve logs from 'DC2'. The RPC server is unavailable. This is often caused by a firewall blocking communication or the RPC service being stopped. Check the Windows Firewall on 'DC2' for 'Remote Event Log Management' rules.

