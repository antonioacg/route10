<html>
<! Copyright (c) Realtek Semiconductor Corp., 2003. All Rights Reserved. ->
<head>
<meta http-equiv="Content-Type" content="text/html" charset="utf-8">
<title>PON WAN</title>
<script type="text/javascript" src="share.js"></script>
<script type="text/javascript" src="common.js"></script>
<script type="text/javascript" src="base64_code.js"></script>
<script language="javascript">

var initConnectMode;
var pppConnectStatus=0;

var dgwstatus;
var gtwy;
var interfaceInfo = '';
var gtwyIfc ='';
var gwInterface=0;
var ipver=1;

var curlink = null;
var ctype = 4;
var reservedVlanA = [0, 0, 4095];
var otherVlanStart = 4000;
var otherVlanEnd = 4010;
var alertVlanStr = "0, 0, 4000 ~ 4010, 4095";

var cgi = new Object();
var links = new Array();

with(links){}



function pppTypeSelection()
{
 if ( document.ethwan.pppConnectType.selectedIndex == 2) {
  document.ethwan.pppIdleTime.value = "";
  disableTextField(document.ethwan.pppIdleTime);
 }
 else {
  if (document.ethwan.pppConnectType.selectedIndex == 1) {
   enableTextField(document.ethwan.pppIdleTime);
  }
  else {
   document.ethwan.pppIdleTime.value = "";
   disableTextField(document.ethwan.pppIdleTime);
  }
 }
}

function checkDefaultGW() {
 with (document.forms[0]) {
  if (droute[0].checked == false && droute[1].checked == false && gwStr[0].checked == false && gwStr[1].checked == false) {
   alert('A default gateway has to be selected.');
   return false;
  }
  if (droute[1].checked == true) {
   if (gwStr[0].checked == true) {
    if (isValidIpAddress(dstGtwy.value, "Default Gateway IP Address") == false)
     return false;
   }
  }
 }
 return true;
}

function check_dhcp_opts()
{
 with (document.forms[0])
 {
  /* Option 60 */
  if(typeof enable_opt_60 !== 'undefined' &&enable_opt_60.checked)
  {
   if (opt60_val.value=="") {
    alert('Vendor ID cannot be empty!');
    opt60_val.focus();
    return false;
   }
   if (checkString(opt60_val.value) == 0) {
    alert('Invalid Vendor ID.');
    opt60_val.focus();
    return false;
   }
  }

  /* Option 61 */
  if(typeof enable_opt_61 !== 'undefined'&&enable_opt_61.checked)
  {
   if (iaid.value=="") {
    alert('IAID cannot be empty!');
    iaid.focus();
    return false;
   }
   if (checkDigit(iaid.value) == 0) {
    alert('IAID should be a number.');
    iaid.focus();
    return false;
   }

   if(duid_type[1].checked)
   {
    /* Enterprise number + Identifier*/
    if (duid_ent_num.value=="") {
     alert('Enterprise number cannot be empty!');
     duid_ent_num.focus();
     return false;
    }
    if (checkDigit(duid_ent_num.value) == 0) {
     alert('Enterprise number should be a number.');
     duid_ent_num.focus();
     return false;
    }

    if (duid_id.value=="") {
     alert('DUID Identifier cannot be empty!');
     duid_id.focus();
     return false;
    }
    if (checkString(duid_id.value) == 0) {
     alert('Invalid DUID Identifier.');
     duid_id.focus();
     return false;
    }
   }
  }

  if(typeof enable_opt_125 !== 'undefined' &&enable_opt_125.checked)
  {
   if (manufacturer.value=="") {
    alert('Manufacturer OUI cannot be empty!');
    manufacturer.focus();
    return false;
   }
   if (checkString(manufacturer.value) == 0) {
    alert('Invalid Manufacturer OUI.');
    manufacturer.focus();
    return false;
   }

   if (product_class.value=="") {
    alert('Product Class cannot be empty!');
    product_class.focus();
    return false;
   }
   if (checkString(product_class.value) == 0) {
    alert('Invalid Product Class.');
    product_class.focus();
    return false;
   }

   if (model_name.value=="") {
    alert('Model Name cannot be empty!');
    model_name.focus();
    return false;
   }
   if (checkString(model_name.value) == 0) {
    alert('Invalid Model Name.');
    model_name.focus();
    return false;
   }

   if (serial_num.value=="") {
    alert('Serial Number cannot be empty!');
    serial_num.focus();
    return false;
   }
   if (checkString(serial_num.value) == 0) {
    alert('Serial Number cannot be empty!');
    serial_num.focus();
    return false;
   }
  }
 }
}
function isAllStar(str)
{
  for (var i=0; i<str.length; i++) {
   if ( str.charAt(i) != '*' ) {
   return false;
 }
  }
  return true;
}
function disableUsernamePassword()
{
 //avoid sending username/password without encode
 disableTextField(document.ethwan.pppUserName);
 if(!isAllStar(document.ethwan.pppPassword.value))
  disableTextField(document.ethwan.pppPassword);
}
function applyCheck()
{
 var tmplst = "";
 var ptmap = 0;
 var pmchkpt = document.getElementById("tbl_pmap");

 if (pmchkpt) {
  with (document.forms[0]) {
   for (var i = 0; i < 14; i++) {
    /* chkpt do not always have 14 elements */
    if (!chkpt[i])
     break;

    if (chkpt[i].checked == true)
     ptmap |= (0x1 << i);
   }
   itfGroup.value = ptmap;
  }
 }

 if (checkDefaultGW()==false)
  return false;

 if (document.ethwan.vlan.checked == true) {
  if (document.ethwan.vid.value == "") {
   alert('VID should not be empty!');
   document.ethwan.vid.focus();
   return false;
  }
  else if(document.ethwan.vid.value<0 ||document.ethwan.vid.value>4095) {
    alert("Incorrect vlan id, shoule be 1~4095");
    return false;
  }
  else if((sji_checkdigitrange(document.ethwan.vid.value, otherVlanStart, otherVlanEnd) == true) || (check_vlan_reserved(document.ethwan.vid.value) == true))
  {
   document.ethwan.vid.focus();
   alert("VLAN ID \"" + document.ethwan.vid.value + "\" is internal reserved vlan");
   return;
  }

 }

 if ( document.ethwan.adslConnectionMode.value == 2 ) {
  if (document.ethwan.pppUserName.value=="") {
   alert('PPP user name cannot be empty!');
   document.ethwan.pppUserName.focus();
   return false;
  }
  if (includeSpace(document.ethwan.pppUserName.value)) {
   alert('Cannot accept space character in PPP user name.');
   document.ethwan.pppUserName.focus();
   return false;
  }
  if (checkString(document.ethwan.pppUserName.value) == 0) {
   alert('Invalid PPP user name.');
   document.ethwan.pppUserName.focus();
   return false;
  }
  document.ethwan.encodePppUserName.value=encode64(document.ethwan.pppUserName.value);

  if (document.ethwan.pppPassword.value=="") {
   alert('PPP password cannot be empty!');
   document.ethwan.pppPassword.focus();
   return false;
  }

  if(!isAllStar(document.ethwan.pppPassword.value)){
   if (includeSpace(document.ethwan.pppPassword.value)) {
    alert('Cannot accept space character in PPP password.');
    document.ethwan.pppPassword.focus();
    return false;
   }
   if (checkString(document.ethwan.pppPassword.value) == 0) {
    alert(' Invalid PPP password.');
    document.ethwan.pppPassword.focus();
    return false;
   }
   document.ethwan.encodePppPassword.value=encode64(document.ethwan.pppPassword.value);
  }

  if (document.ethwan.pppConnectType.selectedIndex == 1) {
   if (document.ethwan.pppIdleTime.value <= 0) {
    alert('Invalid PPP idle time.');
    document.ethwan.pppIdleTime.focus();
    return false;
   }
  }
 }

 if (document.ethwan.dns1.value !="")
 {
  if (!checkHostIP(document.ethwan.dns1, 1))
  {
   document.ethwan.dns1.focus();
   return false;
  }
 }

 if (document.ethwan.dns2.value !="")
 {
  if (!checkHostIP(document.ethwan.dns2, 1))
  {
   document.ethwan.dns2.focus();
   return false;
  }
 }


 if (1) {
  if(document.ethwan.IpProtocolType.value & 1){
   if ( document.ethwan.adslConnectionMode.value == 1 ) {
    if (document.ethwan.ipMode[0].checked)
    {
     /*Fixed IP*/
     if ( document.ethwan.ipUnnum.disabled || ( !document.ethwan.ipUnnum.disabled && !document.ethwan.ipUnnum.checked )) {
      if (!checkHostIP(document.ethwan.ip, 1))
       return false;
      if (document.ethwan.remoteIp.visiblity == "hidden") {
       if (!checkHostIP(document.ethwan.remoteIp, 1))
       return false;
      }
      if (document.ethwan.adslConnectionMode.value == 1 && !checkNetmask(document.ethwan.netmask, 1))
       return false;
     }
    }
    else
    {
     /* DHCP */
     if(check_dhcp_opts() == false)
      return false;
    }
   }
  }
 }

 if (1) {
  /* Not bridged mode & choosing IPv6 */
  if (document.ethwan.adslConnectionMode.value != 0
   && (document.ethwan.IpProtocolType.value & 2)) {
   if (document.ethwan.adslConnectionMode.value != 0 && document.ethwan.adslConnectionMode.value != 6 && document.ethwan.adslConnectionMode.value != 8) {
    if(document.ethwan.slacc.checked == false && document.ethwan.itfenable.checked == false && document.ethwan.staticIpv6.checked == false){
     alert('Please input ipv6 address or select DHCPv6 client or click SLAAC!');
     document.ethwan.slacc.focus();
     return false;
    }
   }

   if(document.ethwan.itfenable.checked) {
    if(document.ethwan.iana.checked == false && document.ethwan.iapd.checked == false ) {
     alert('Please select iana or iapd!');
     document.ethwan.iana.focus();
     return false;
    }
   }

   if(document.ethwan.staticIpv6.checked) {
    if(document.ethwan.Ipv6Addr.value == "" || document.ethwan.Ipv6PrefixLen.value == "") {
     alert('Please input ipv6 address and Prefix Length!');
     document.ethwan.Ipv6Addr.focus();
     return false;
    }
    if(document.ethwan.Ipv6Addr.value != ""){
     if (! isGlobalIpv6Address( document.ethwan.Ipv6Addr.value) ){
      alert('Invalid ipv6 address!');
      document.ethwan.Ipv6Addr.focus();
      return false;
     }
     var prefixlen= getDigit(document.ethwan.Ipv6PrefixLen.value, 1);
     if (prefixlen > 128 || prefixlen <= 0) {
      alert('Invalid ipv6 prefix length!');
      document.ethwan.Ipv6PrefixLen.focus();
      return false;
     }
    }
    if(document.ethwan.Ipv6Gateway.value != "" ){
     if (! isUnicastIpv6Address( document.ethwan.Ipv6Gateway.value) ){
      alert('Invalid ipv6 gateway address!');
      document.ethwan.Ipv6Gateway.focus();
      return false;
     }
    }
    if(document.ethwan.Ipv6Dns1.value != "" ){
     if (! isIpv6Address( document.ethwan.Ipv6Dns1.value) ){
      alert('Invalid primary IPv6 DNS address!');
      document.ethwan.Ipv6Dns1.focus();
      return false;
     }
    }
    if(document.ethwan.Ipv6Dns2.value != "" ){
     if (! isIpv6Address( document.ethwan.Ipv6Dns2.value) ){
      alert('Invalid secondary IPv6 DNS address!');
      document.ethwan.Ipv6Dns2.focus();
      return false;
     }
    }
   }
   else{
    document.ethwan.Ipv6Addr.value = "";
    document.ethwan.Ipv6PrefixLen.value = "";
    document.ethwan.Ipv6Gateway.value = "";
    document.ethwan.Ipv6Dns1.value = "";
    document.ethwan.Ipv6Dns2.value = "";
   }

   if (0) {

    if (document.ethwan.adslConnectionMode.value == 8) // 6rd
    {
     if(document.ethwan.SixrdBRv4IP.value == ""){
      alert('Invalid 6rd Board Router v4IP address!');
      document.ethwan.SixrdBRv4IP.focus();
      return false;
     }

     if(document.ethwan.SixrdIPv4MaskLen.value == ""){
      alert('Invalid 6rd IPv4 Mask length address!');
      document.ethwan.SixrdIPv4MaskLen.focus();
      return false;
     }

     if(document.ethwan.SixrdPrefix.value == ""){
      alert('Invalid 6rd Prefix address!');
      document.ethwan.SixrdPrefix.focus();
      return false;
     }

     if(document.ethwan.SixrdPrefixLen.value == ""){
      alert('Invalid 6rd Prefix length address!');
      document.ethwan.SixrdPrefixLen.focus();
      return false;
     }
    }
    else{

     document.ethwan.SixrdBRv4IP.value = "";
     document.ethwan.SixrdIPv4MaskLen.value = "";
     document.ethwan.SixrdPrefix.value = "";
     document.ethwan.SixrdPrefixLen.value = "";
    }

   }

   if (0) {
    if (document.ethwan.adslConnectionMode.value == 6) // DS-Lite
    {
     if(document.ethwan.DSLiteLocalIP.value != ""){
      if (! isGlobalIpv6Address( document.ethwan.DSLiteLocalIP.value) ){
       alert('Invalid DSLiteLocalIP address!');
       document.ethwan.DSLiteLocalIP.focus();
       return false;
      }
     }

     if(document.ethwan.DSLiteRemoteIP.value != ""){
      if (! isGlobalIpv6Address( document.ethwan.DSLiteRemoteIP.value) ){
       alert('Invalid DSLiteRemoteIP address!');
       document.ethwan.DSLiteRemoteIP.focus();
       return false;
      }
     }

     if(document.ethwan.DSLiteGateway.value != ""){
      if (! isGlobalIpv6Address( document.ethwan.DSLiteGateway.value) ){
       alert('Invalid DSLiteGateway address!');
       document.ethwan.DSLiteGateway.focus();
       return false;
      }
     }
    }
    else{
     document.ethwan.DSLiteLocalIP.value = "";
     document.ethwan.DSLiteRemoteIP.value = "";
     document.ethwan.DSLiteGateway.value = "";
    }
   }
  }
 }

 if(document.ethwan.lkname.value != "new") tmplst = curlink.name;
 document.ethwan.lst.value = tmplst;
 //avoid sending username/password without encode
 disableUsernamePassword();

 return true;
}

function deleteCheck()
{
 var tmplst = "";

 if ( document.ethwan.lkname.value == "new" )
 {
  alert('no link selected!');
  return false;
 }

 tmplst = curlink.name;
 document.ethwan.lst.value = tmplst;

 disableUsernamePassword();

 return true;
}

function setPPPConnected()
{
 pppConnectStatus = 1;
}

function dnsModeClicked()
{
 if ( document.ethwan.dnsMode[0].checked )
 {
  disableTextField(document.ethwan.dns1);
  disableTextField(document.ethwan.dns2);
 }

 if ( document.ethwan.dnsMode[1].checked )
 {
  enableTextField(document.ethwan.dns1);
  enableTextField(document.ethwan.dns2);
 }
}

function disableFixedIpInput()
{
 disableTextField(document.ethwan.ip);
 disableTextField(document.ethwan.remoteIp);
 disableTextField(document.ethwan.netmask);

 document.ethwan.dnsMode[0].disabled = false;
 document.ethwan.dnsMode[1].disabled = false;
 dnsModeClicked();
}

function enableFixedIpInput()
{
 enableTextField(document.ethwan.ip);
 enableTextField(document.ethwan.remoteIp);
 if (document.ethwan.adslConnectionMode.value == 4)
  disableTextField(document.ethwan.netmask);
 else
  enableTextField(document.ethwan.netmask);

 document.ethwan.dnsMode[0].disabled = true;
 document.ethwan.dnsMode[1].disabled = true;
 dnsModeClicked();
}

function ipTypeSelection(init)
{
 if ( document.ethwan.ipMode[0].checked ) {
  enableFixedIpInput();
  showDhcpOptSettings(0);
 } else {
  disableFixedIpInput();
  showDhcpOptSettings(1);
 }

 if (init == 0)
 {
  if ( document.ethwan.ipMode[0].checked )
   document.ethwan.dnsMode[1].checked = true;
  else
   document.ethwan.dnsMode[0].checked = true;
  dnsModeClicked();
 }
}

function enable_pppObj()
{
 enableTextField(document.ethwan.pppUserName);
 enableTextField(document.ethwan.pppPassword);
 enableTextField(document.ethwan.pppConnectType);
 document.ethwan.gwStr[0].disabled = false;
 document.ethwan.gwStr[1].disabled = false;
 enableTextField(document.ethwan.dstGtwy);
 document.ethwan.wanIf.disabled = false;
 pppTypeSelection();
 autoDGWclicked();
}

function pppSettingsEnable()
{
 document.getElementById('tbl_ppp').style.display='block';
 enable_pppObj();
}

function disable_pppObj()
{
 disableTextField(document.ethwan.pppUserName);
 disableTextField(document.ethwan.pppPassword);
 disableTextField(document.ethwan.pppIdleTime);
 disableTextField(document.ethwan.pppConnectType);

 document.ethwan.gwStr[0].disabled = true;
 document.ethwan.gwStr[1].disabled = true;
 disableTextField(document.ethwan.dstGtwy);
 document.ethwan.wanIf.disabled = true;
}

function pppSettingsDisable()
{
 document.getElementById('tbl_ppp').style.display='none';
 disable_pppObj();
}

function enable_ipObj()
{
 document.ethwan.ipMode[0].disabled = false;
 document.ethwan.ipMode[1].disabled = false;
 document.ethwan.gwStr[0].disabled = false;
 document.ethwan.gwStr[1].disabled = false;
 enableTextField(document.ethwan.dstGtwy);
 document.ethwan.wanIf.disabled = false;
 ipTypeSelection(1);
 autoDGWclicked();
}

function ipSettingsEnable()
{
 //if (ipver == 2)
 //	return;
 document.getElementById('tbl_ip').style.display='block';
 enable_ipObj();
}

function disable_ipObj()
{
 document.ethwan.ipMode[0].disabled = true;
 document.ethwan.ipMode[1].disabled = true;
 document.ethwan.gwStr[0].disabled = true;
 document.ethwan.gwStr[1].disabled = true;
 disableTextField(document.ethwan.dstGtwy);
 document.ethwan.wanIf.disabled = true;
 disableFixedIpInput();
}

function ipSettingsDisable()
{
 document.getElementById('tbl_ip').style.display='none';
 showDhcpOptSettings(0);
 disable_ipObj();
}

function showDuidType2(show)
{
 if(show == 1)
 {
  document.getElementById('duid_t2_ent').style.display = '';
  document.getElementById('duid_t2_id').style.display = '';
 }
 else
 {
  document.getElementById('duid_t2_ent').style.display = 'none';
  document.getElementById('duid_t2_id').style.display = 'none';
 }
}

function showDhcpOptSettings(show)
{
 var dhcp_opt = document.getElementById('tbl_dhcp_opt');

 if(dhcp_opt == null)
  return ;

 if(show == 1)
 {
  document.getElementById('tbl_dhcp_opt').style.display='block';

  if(document.ethwan.duid_type[1].checked == true)
   showDuidType2(1);
  else
   showDuidType2(0);
 }
 else
  document.getElementById('tbl_dhcp_opt').style.display='none';
}

function ipModeSelection()
{
 if (document.ethwan.ipUnnum.checked) {
  disable_pppObj();
  disable_ipObj();
  document.ethwan.gwStr[0].disabled = false;
  document.ethwan.gwStr[1].disabled = false;
  enableTextField(document.ethwan.dstGtwy);
  document.ethwan.wanIf.disabled = false;
 }
 else
  enable_ipObj();
}

function updateBrMode(isLinkChanged)
{
 var brmode_ops = document.getElementById('brmode');

 if(!brmode_ops)
  return ;

 // reset to transparent bridge
 if(!isLinkChanged)
 {
  document.ethwan.br.checked = false;
  brmode_ops.value = 0;
  brmode_ops.disabled = true;
 }

 if(document.ethwan.adslConnectionMode.value == 0)
 {
  document.getElementById('br_row').style.display = "none";
  brmode_ops.disabled = false;
 }
 else
 {
  document.getElementById('br_row').style.display = "";
 }
}

function brClicked()
{
 var brmode_ops = document.getElementById('brmode');

 if(!brmode_ops)
  return ;

 if(document.ethwan.br.checked)
  brmode_ops.disabled = false;
 else
  brmode_ops.disabled = true;
}

function adslConnectionModeSelection(isLinkChanged)
{
 document.ethwan.naptEnabled.disabled = false;
 document.ethwan.igmpEnabled.disabled = false;
 document.ethwan.ipUnnum.disabled = true;

 document.ethwan.droute[0].disabled = false;
 document.ethwan.droute[1].disabled = false;
 if(!isLinkChanged)
  document.ethwan.mtu.value = 1500;
 document.getElementById('tbl_ppp').style.display='none';
 document.getElementById('tbl_ip').style.display='none';

 if(document.getElementById('tbl_dhcp_opt') != null)
  document.getElementById('tbl_dhcp_opt').style.display='none';

 document.getElementById('6rdDiv').style.display='none';
 if (1) {
  ipv6SettingsEnable();
  document.getElementById('tbprotocol').style.display="block";
  document.ethwan.IpProtocolType.disabled = false;
  if (0) {
   document.getElementById('DSLiteDiv').style.display="none";
  }
 }else
  document.getElementById('tbprotocol').style.display="none";

 //e = document.getElementById("qosEnabled");
 //if (e) e.disabled = false;
 //alert(document.ethwan.adslConnectionMode.value);
 switch(document.ethwan.adslConnectionMode.value){
  case '0':// bridge mode
   document.getElementById('tbprotocol').style.display="none";
   document.getElementById('tbmtu').style.display='none';
  //case '3':// DS-Lite
  case '6':// DS-Lite
   document.ethwan.naptEnabled.disabled = true;
   document.ethwan.igmpEnabled.disabled = true;
   document.ethwan.droute[0].disabled = true;
   document.ethwan.droute[1].disabled = true;
   pppSettingsDisable();
   ipSettingsDisable();

   if (1) {
    ipv6SettingsDisable();
    document.getElementById('tbprotocol').style.display="none";
   }

   // For DS-Lite only
   if (1 && 0) {
    if ( document.ethwan.adslConnectionMode.value == 6 )
    {
     document.getElementById('tbmtu').style.display='block';
     document.getElementById('DSLiteDiv').style.display='block';
     document.ethwan.droute[0].disabled = false;
     document.ethwan.droute[1].disabled = false;
     //document.ethwan.qosEnabled.disabled = true;
     //document.getElementById('tbprotocol').style.display="block";

     // Set some values for DS-Lite mer mode only
     document.ethwan.IpProtocolType.value = 2; // IPV6 only
     //document.ethwan.IpProtocolType.disabled = true;
     document.ethwan.slacc.checked = false; // not use slaac
     document.ethwan.staticIpv6.checked = false; // not use static IP
     document.ethwan.itfenable.checked = false; // not enable DHCPv6 client
    }
   }
   //if (e) e.disabled = false;
   break;
  case '8': //6rd
   if (1 && 0)
   {
    document.getElementById('tbmtu').style.display='block';
    document.getElementById('6rdDiv').style.display='block';
    document.ethwan.droute[0].checked = false;
    document.ethwan.droute[1].checked = true;
    // Set some values for DS-Lite mer mode only
    document.ethwan.IpProtocolType.value = 3; // IPV4/IPV6
    //document.ethwan.IpProtocolType.disabled = true;
    document.ethwan.slacc.checked = false; // not use slaac
    document.ethwan.staticIpv6.checked = false; // not use static IP
    document.ethwan.itfenable.checked = false; // not enable DHCPv6 client
    ipSettingsEnable();
    enableFixedIpInput();
    ipv6SettingsDisable();
    document.getElementById('tbprotocol').style.display="none";
   }
            break;
  case '1'://1483mer
   document.getElementById('tbmtu').style.display='block';
   pppSettingsDisable();
   if (1) {
    if(document.ethwan.IpProtocolType.value != 2) // It is not IPv6 only
     ipSettingsEnable();
   }
   else
    ipSettingsEnable();
   if(!isLinkChanged)
    document.ethwan.naptEnabled.checked = true;
   break;
  case '2'://pppoe
   if(!isLinkChanged)
    document.ethwan.mtu.value = 1492;
   document.getElementById('tbmtu').style.display='block';
   document.getElementById('tbl_ppp').style.display='block';
   ipSettingsDisable();
   pppSettingsEnable();
   if(!isLinkChanged)
    document.ethwan.naptEnabled.checked = true;
   break;
  default:
   pppSettingsDisable();
   ipSettingsEnable();
 }

 updateBrMode(isLinkChanged);
}

function naptClicked()
{
 if (document.ethwan.adslConnectionMode.value == 3) {
  // Route1483
  if (document.ethwan.naptEnabled.checked == true) {
   document.ethwan.ipUnnum.checked = false;
   document.ethwan.ipUnnum.disabled = true;
  }
  else
   document.ethwan.ipUnnum.disabled = false;
  ipModeSelection();
 }
}

function vlanClicked()
{
 if (document.ethwan.vlan.checked)
 {
  document.ethwan.vid.disabled = false;
  document.ethwan.vprio.disabled = false;
 }
 else {
  document.ethwan.vid.disabled = true;
  document.ethwan.vprio.disabled = true;
 }
}

function hideGWInfo(hide) {
 var status = false;

 if (hide == 1)
  status = true;

 changeBlockState('gwInfo', status);

 if (hide == 0) {
  with (document.forms[0]) {
   if (dgwstatus == 255) {
    if (isValidIpAddress(gtwy) == true) {
     gwStr[0].checked = true;
     gwStr[1].checked = false;
     dstGtwy.value=gtwy;
     wanIf.disabled=true
    } else {
     gwStr[0].checked = false;
     gwStr[1].checked = true;
     dstGtwy.value = '';
    }
   }
   else if (dgwstatus != 239) {
     gwStr[1].checked = true;
     gwStr[0].checked = false;
     wanIf.disabled=false;
     wanIf.value=dgwstatus;
     dstGtwy.disabled=true;
   } else {
     gwStr[1].checked = false;
     gwStr[0].checked = true;
     wanIf.disabled=true;
     dstGtwy.disabled=false;
   }
  }
 }
}

function autoDGWclicked() {
 if (document.ethwan.droute[0].checked == true) {
  hideGWInfo(1);
 } else {
  hideGWInfo(0);
 }
}

function gwStrClick() {
 with (document.forms[0]) {
  if (gwStr[1].checked == true) {
   dstGtwy.disabled = true;
   wanIf.disabled = false;
  }
  else {
   dstGtwy.disabled = false;
   wanIf.disabled = true;
  }
       }
}

function dhcp6cEnable()
{
 if(document.ethwan.itfenable.checked)
  document.getElementById('dhcp6c_block').style.display="block";
 else
  document.getElementById('dhcp6c_block').style.display="none";
}

function ipv6StaticUpdate()
{
 if(document.ethwan.staticIpv6.checked)
  document.getElementById('secIPv6Div').style.display="block";
 else
  document.getElementById('secIPv6Div').style.display="none";
}

function ipv6WanUpdate()
{
 ipv6StaticUpdate();
 dhcp6cEnable();
}

function ipv6SettingsDisable()
{
 document.getElementById('tbipv6wan').style.display="none";
 document.getElementById('secIPv6Div').style.display="none";
 document.getElementById('dhcp6c_ctrlblock').style.display="none";
}

function ipv6SettingsEnable()
{
 if(document.ethwan.IpProtocolType.value != 1){
  document.getElementById('tbipv6wan').style.display="block";
  document.getElementById('dhcp6c_ctrlblock').style.display="block";
  ipv6WanUpdate();
   }
}

function protocolChange()
{
 ipver = document.ethwan.IpProtocolType.value;
 if(document.ethwan.IpProtocolType.value == 1){
  if( document.ethwan.adslConnectionMode.value ==1 ||
   document.ethwan.adslConnectionMode.value ==4 ||
   document.ethwan.adslConnectionMode.value ==5)
   ipSettingsEnable();
   ipv6SettingsDisable();
 }else{
  if(document.ethwan.IpProtocolType.value == 2){
   ipSettingsDisable();
  }else{
   if( document.ethwan.adslConnectionMode.value ==1 ||
    document.ethwan.adslConnectionMode.value ==4 ||
    document.ethwan.adslConnectionMode.value ==5)
    ipSettingsEnable();
  }
  ipv6SettingsEnable();
 }
}
/* Mason Yu:20110307 END */

function on_linkchange(itlk)
{
 var pmchkpt = document.getElementById("tbl_pmap");

 with ( document.forms[0] )
 {
  if(itlk == null)
  {
   //select
   adslConnectionMode.value = pppConnectType.value = 0;

   if(typeof brmode != "undefined") // "undefined" refer to an object is not defined and defined but without a value. Be careful!
    brmode.value = 0;

   IpProtocolType.value = 1;
   // ctype
   ctype.value = 2;

   //radio
   ipMode[0].checked = droute[0].checked = dnsMode[1].checked = true;
   chEnable[0].checked = true;
   if(typeof duid_type !== 'undefined')
    duid_type[1].checked = true;

   //checkbox
   naptEnabled.checked = vlan.checked = qosEnabled.checked = igmpEnabled.checked = false;
   if(typeof enable_opt_60 !== 'undefined')
    enable_opt_60.checked = enable_opt_61.checked = enable_opt_125.checked = false;

   //input number
   vprio.value = vid.value = "0";
   vid.value = "";
   //input ip
   ip.value = remoteIp.value = "0.0.0.0";
   netmask.value = "255.255.255.0";

   //input text
   pppUserName.value = pppPassword.value = acName.value = serviceName.value = dns1.value = dns2.value = "";
   auth.value = 0;

   //checkbox
   slacc.checked = staticIpv6.checked = itfenable.checked = false;

   if(typeof document.ethwan.br != "undefined") // "undefined" refer to an object is not defined and defined but without a value. Be careful!
    document.ethwan.br.checked = false;

   //port mapping
   if (pmchkpt)
    for (var i = 0; i < 14; i++) {
     /* chkpt do not always have 14 elements */
     if (!chkpt[i])
      break;

     chkpt[i].checked = false;
    }

    for(var k in links)
    {
     var lk = links[k];
     for (var i = 0; i < 14; i++)
     {
      /* chkpt do not always have 14 elements */
      if (!chkpt[i])
       break;
      if(k == 0)
                  {
                      chkpt[i].disabled = false;
                  }
      if((lk.itfGroup & (0x1 << i)) != 0)
      {
       chkpt[i].disabled = true;
      }
     }
    }

    document.ethwan.apply.disabled = false;
    document.ethwan.delete.disabled = false;
    document.getElementById('wan_olt_id').style.display = 'none';
  }
  else
  {
   //sji_onchanged(document, itlk);
   mtu.value=itlk.mtu;
   //select
   adslConnectionMode.value = itlk.cmode;

   //ctype
   ctype.value = itlk.applicationtype;

   //brmode
   if(document.ethwan.br)
   {
    document.ethwan.br.checked = false;
    if(itlk.brmode == 2)
    {
     // Disable Bridge
     brmode.value = 0;
     brmode.disabled = true;
    }
    else
    {
     // Enable Bridge
     if(itlk.cmode != 0)
      document.ethwan.br.checked = true;

     brmode.value = itlk.brmode;
     brmode.disabled = false;
    }
   }

   //checkbox
   if (itlk.napt == 1)
    naptEnabled.checked = true;
   else
    naptEnabled.checked = false;
   if (itlk.enableIGMP == 1)
    igmpEnabled.checked = true;
   else
    igmpEnabled.checked = false;
   if (itlk.enableIpQos == 1)
    qosEnabled.checked = true;
   else
    qosEnabled.checked = false;
   mtu.value = itlk.mtu;
   if (itlk.vlan == 1)
   {
    vlan.checked = true;
    vid.value = itlk.vid;
    vprio.value = itlk.vprio;
   }
   else
   {
    vlan.checked = false;
    				if(itlk.cmode == 0)
					vid.value = 9
				else
					vid.value = 8

   }
   //radio
   if (itlk.dgw == 1)
    droute[1].checked = true;
   else
    droute[0].checked = true;
   if (itlk.enable == 1)
    chEnable[0].checked = true;
   else
    chEnable[1].checked = true;

   //radio
   if(itlk.cmode != 0)//not bridge
   {
    IpProtocolType.value = itlk.IpProtocol;
    if (IpProtocolType.value != 1)
    {
     if (itlk.AddrMode & 1)
      slacc.checked = true;
     else
      slacc.checked = false;
     if (itlk.AddrMode & 2)
     {
      staticIpv6.checked = true;
      Ipv6Addr.value = itlk.Ipv6Addr;
      Ipv6PrefixLen.value = itlk.Ipv6AddrPrefixLen;
      Ipv6Gateway.value = itlk.RemoteIpv6Addr;
      Ipv6Dns1.value = itlk.Ipv6Dns1;
      Ipv6Dns2.value = itlk.Ipv6Dns2;
     }
     else
     {
      staticIpv6.checked = false;
      Ipv6Addr.value = "";
      Ipv6PrefixLen.value = "";
      Ipv6Gateway.value = "";
      Ipv6Dns1.value = "";
      Ipv6Dns2.value = "";
     }

     if (itlk.Ipv6Dhcp)
     {
      itfenable.checked = true;
      if (itlk.Ipv6DhcpRequest & 1)
       iana.checked = true;
      else
       iana.checked = false;
      if (itlk.Ipv6DhcpRequest & 2)
       iapd.checked = true;
      else
       iapd.checked = false;
     }
     else
      itfenable.checked = false;

     // DS-Lite
     if (itlk.AddrMode & 4)
     {
      DSLiteLocalIP.value = itlk.Ipv6Addr;
      DSLiteRemoteIP.value = itlk.RemoteIpv6EndPointAddr;
      DSLiteGateway.value = itlk.RemoteIpv6Addr;
      adslConnectionMode.value = 6;
     }


     // 6rd
     if (itlk.AddrMode & 8)
     {
      adslConnectionMode.value = 8;
      SixrdBRv4IP.value = itlk.SixrdBRv4IP;
      SixrdIPv4MaskLen.value = itlk.SixrdIPv4MaskLen;
      SixrdPrefix.value = itlk.SixrdPrefix;
      SixrdPrefixLen.value = itlk.SixrdPrefixLen;
      ip.value = itlk.ipAddr;
      remoteIp.value = itlk.remoteIpAddr;
      netmask.value = itlk.netMask;
     }

    }

    if (itlk.cmode == 1)//IPoE
    {
     if (itlk.ipDhcp == 1)
     {
      ipMode[1].checked = true;
      ip.value = "";
      remoteIp.value = "";
      netmask.value = "";
     }
     else
     {
      ipMode[0].checked = true;
      ip.value = itlk.ipAddr;
      remoteIp.value = itlk.remoteIpAddr;
      netmask.value = itlk.netMask;
     }
     if (itlk.dnsMode == 1)
       dnsMode[0].checked = true;
      else
       dnsMode[1].checked = true;
     dns1.value = itlk.v4dns1;
     dns2.value = itlk.v4dns2;
    }
    else if (itlk.cmode == 2)
    {
     pppUserName.value = decode64(itlk.pppUsername);
     pppPassword.value = itlk.pppPassword;
     pppConnectType.value = itlk.pppCtype;
     pppIdleTime.value = itlk.pppIdleTime;
     auth.value = itlk.pppAuth;
     acName.value = itlk.pppACName;
     serviceName.value = itlk.pppServiceName;
    }
    protocolChange();
   }

   //DHCP options
   if(typeof enable_opt_60 !== 'undefined')
   {
    //assume all other elements are existed if enable_opt_60 is existed

    if(itlk.enable_opt_60)
     enable_opt_60.checked = true;

    opt60_val.value = itlk.opt60_val;

    if(itlk.enable_opt_61)
     enable_opt_61.checked = true;

    iaid.value = itlk.iaid;

    if(itlk.duid_type == 0)
     duid_type[0].checked = true;
    else
     duid_type[itlk.duid_type - 1].checked = true;
    duid_ent_num.value = itlk.duid_ent_num;
    duid_id.value = itlk.duid_id;

    if(itlk.enable_opt_125)
     enable_opt_125.checked = true;

    manufacturer.value = itlk.manufacturer;
    product_class.value = itlk.product_class;
    model_name.value = itlk.model_name;
    serial_num.value = itlk.serial_num;
   }
   //port mapping
   if (pmchkpt)
    for (var i = 0; i < 14; i++) {
     /* chkpt do not always have 14 elements */
     if (!chkpt[i])
      break;

     chkpt[i].checked = (itlk.itfGroup & (0x1 << i));
    }

    for(var k in links)
    {
     var lk = links[k];
     for (var i = 0; i < 14; i++)
     {
      /* chkpt do not always have 14 elements */
      if (!chkpt[i])
       break;
      if(k == 0)
                  {
                      chkpt[i].disabled = false;
                  }
      if((lk.itfGroup & (0x1 << i)) != 0)
      {
       if(lk.name != itlk.name)
       {
        chkpt[i].disabled = true;
       }
      }
     }
    }

    if(itlk.omci_configured)
    {
     document.ethwan.apply.disabled = true;
     document.ethwan.delete.disabled = true;
     document.getElementById('wan_olt_id').style.display = '';
    }
    else
    {
     document.ethwan.delete.disabled = false;
     document.ethwan.apply.disabled = false;
     document.getElementById('wan_olt_id').style.display = 'none';
    }
  }

 }
 ipver = document.ethwan.IpProtocolType.value;

 vlanClicked();
 autoDGWclicked();
 adslConnectionModeSelection(true);
}

function check_vlan_reserved(vlanID)
{
 var num = reservedVlanA.length;
 //var vlanID = document.forms[0].vid.value;
 for(var i = 0; i<num; i++){
  if(vlanID == reservedVlanA[i])
   return true;
 }

 return false;
}

function on_ctrlupdate()
{
 with ( document.forms[0] )
 {
  if(lkname.value == "new")
  {
   curlink = null;
   on_linkchange(curlink);
  }
  else
  {
   curlink = links[lkname.value];
   on_linkchange(curlink);
  }
 }
}

function on_init()
{
 sji_docinit(document, cgi);

 with ( document.forms[0] )
 {
  for(var k in links)
  {
   var lk = links[k];
   lkname.options.add(new Option(lk.name, k));
  }
  lkname.options.add(new Option("new link", "new"));

  if(links.length > 0) lkname.selectedIndex = 0;
  on_ctrlupdate();
 }
}

/*
function SubmitWANMode() // Magician: ADSL/Ethernet WAN mode switch
{
	var wmmap = 0;
	var config_num = 4;

	with (document.forms[0])
	{
		for(var i = 0; i < config_num; i ++)
			if(wmchkbox[i].checked == true)
				wmmap |= (0x1 << i);

		if(wmmap == 0 || wmmap == wanmode)
			return false;

		wan_mode.value = wmmap;
	}

	return confirm("It needs rebooting to change WAN mode.");
}*/
</script>

</head>
<BODY onLoad="on_init();">
<blockquote>
<h2><font color="#0000FF">PON WAN</font></h2>
<form action=/boaform/admin/formWanEth method=POST name="ethwan">
<table border="0" cellspacing="4" width="800">
  <tr><td><font size=2>
    This page is used to configure the parameters for PONWAN
  </font></td></tr>
  <tr><td><hr size=1 noshade align=top></td></tr>
</table>
<!--<table border="0" cellspacing="4" width="800" style="display:none">
 <tr>
  <td>
   <b>WAN Mode:</b>
   <span style="display: none"><input type="checkbox" value=1 name="wmchkbox">ATM</span>
   <span ><input type="checkbox" value=2 name="wmchkbox">Ethernet</span>
   <span style="display: none"><input type="checkbox" value=4 name="wmchkbox">PTM</span>
   <span style="display: none"><input type="checkbox" value=8 name="wmchkbox">Bonding</span>&nbsp;&nbsp;&nbsp;&nbsp;
   <input type="hidden" name="wan_mode" value=0>
   <input type="submit" value="Submit" name="submitwan" onClick="return SubmitWANMode()">
  </td>
 </tr>
 <tr><td><hr size=1 noshade align=top></td></tr>
</table>-->
<table border=0 width="800" cellspacing=4 cellpadding=0>
 <tr>
  <td>
   <select name="lkname" onChange="on_ctrlupdate()" size="1">
   <!--<option value="new" selected>new link</option></select>-->
  </td>
 </tr>
 <tr id="wan_olt_id">
  <td><font size=2><b>NOTE: </b>This wan is created by the olt!</font></td>
 </tr>
 <tr>
  <td>
   <font size=2><b>Enable VLAN: </b><input type="checkbox" name="vlan" size="2" maxlength="2" value="ON" onClick=vlanClicked()>
  </td>
 </tr>
 <tr>
  <td>
   <font size=2><b>VLAN ID: </b><input type="text" name="vid" size="10" maxlength="15">
  </td>
  <td><font size=2><b>802.1p_Mark </b>
   <select style="WIDTH: 60px" name="vprio">
   <option value="0" > </option>
   <option value="1" > 0 </option>
   <option value="2" > 1 </option>
   <option value="3" > 2 </option>
   <option value="4" > 3 </option>
   <option value="5" > 4 </option>
   <option value="6" > 5 </option>
   <option value="7" > 6 </option>
   <option value="8" > 7 </option>
   </select>
  </td>
 </tr>

 <tr>

 </tr>
 <tr>
  <td>
  <font size=2> <b>Channel Mode:</b><select size="1" name="adslConnectionMode" onChange="adslConnectionModeSelection(false)">
	  <option selected value="0">Bridged</option>
	  <option value="1">IPoE</option>
	  <option value="2">PPPoE</option>
</select></font>

  </td>
 </tr>
 
 <tr>
  <td>
  <font size=2><b>Enable NAPT: </b><input type="checkbox" name="naptEnabled"
size="2" maxlength="2" value="ON" onClick=naptClicked()>
  </td>
  <td style="display: none"><font size=2>
   <b>Enable QoS: </b>
   <input type="checkbox" name="qosEnabled" size="2" maxlength="2" value="ON" >
  </font></td>
 </tr>
 <tr>
  <td><font size=2><b>Admin Status:</b>
   <input type=radio value=1 name="chEnable">Enable
   <input type=radio value=0 name="chEnable" checked>Disable</font>
  </td>
 </tr>
 <tr>
		<td><font size=2><b>Connection Type:</b>
			<select size=1 name="ctype">
				<option  value=4>Other</option>
				<option  value=1>TR069</option>
				<option  value=2>INTERNET</option>
				<option  value=3>INTERNET_TR069</option>
			</select>
		</td>
	</tr>

 <tr>
  <td>
   <font id="tbmtu" size=2><b>MTU: </b><input type="text" name="mtu" size="10" maxlength="15">
  </td>
 </tr>
</table>
<div ID=dgwshow style="display:none">
<table>
<td><font size=2><b>Default Route:</b>
 <input type=radio value=0 name="droute">Disable
 <input type=radio value=1 name="droute" checked>Enable</font>
</td>
</table>
</div>

<div ID=IGMPProxy_show style="display:none">
<table>
 <td><font size=2><b>Enable IGMP-Proxy: </b><input type="checkbox" name="igmpEnabled"
size="2" maxlength="2" value="ON"></td>
</table>
</div>

<table id="tbprotocol"  border=0 width="800" cellspacing=4 cellpadding=0>
	<tr><td colspan=5><hr size=2 align=top></td></tr>
	<tr nowrap id=TrIpProtocolType>
		<td width="120px"><font size=2><b>IP Protocol:</b></td>
		<td><select id="IpProtocolType" style="WIDTH: 130px" onChange="protocolChange()" name="IpProtocolType">
			<option value="1" > IPv4</option>
			<option value="2" > IPv6</option>
			<option value="3" > IPv4/IPv6</option>
			</select>
		</td>
	</tr>
</table>


<table id=tbl_ppp border=0 width=800 cellspacing=4 cellpadding=0>
<tr><td colspan=5><hr size=2 align=top></td></tr>
<tr><th align="left"><font size=2><b>PPP Settings:</b></th>
	<td><font size=2><b>UserName:</b></td>
	<td><font size=2><input type="text" name="pppUserName" size="16" maxlength="63"></td>
	<td><font size=2><b>Password:</b></td>
	<td><font size=2><input type="password" name="pppPassword" size="10" maxlength="29"></td>
</tr>
<tr><th></th>
	<td><font size=2><b>Type:</b></td>
	<td><font size=2><select size="1" name="pppConnectType" onChange="pppTypeSelection()">
		<option selected value="0">Continuous</option>
		<option value="1">Connect on Demand</option>
		<option value="2">Manual</option>
		</select>
	</td>
	<td><font size=2><b>Idle Time (sec):</b></td>
	<td><font size=2><input type="text" name="pppIdleTime" size="10" maxlength="10"></td>
</tr>
<tr><th></th>
	<td><font size=2><b>Authentication Method:</b></td>
	<td><font size=2><select size="1" name="auth">
		<option selected value="0">AUTO</option>
		<option value="1">PAP</option>
		<option value="2">CHAP</option>
		</select>
	</td>
</tr>
<tr><th></th>
	<td><font size=2><b>AC-Name:</b></td>
	<td><font size=2><input type="text" name="acName" size="16" maxlength="30"></td>
	<td><font size=2><b>Service-Name:</b></td>
	<td><font size=2><input type="password" name="serviceName" size="10" maxlength="30"></td>
</tr>
</table>
<table id=tbl_ip border=0 width=800 cellspacing=4 cellpadding=0>
<tr><td colspan=5><hr size=2 align=top></td></tr>
<tr><th align="left"><font size=2><b>WAN IP Settings:</b></th>

	<td><font size=2><b>Type:</b></td>
	<td><font size=2>
	<input type="radio" value="0" name="ipMode" checked onClick="ipTypeSelection(0)">Fixed IP
	<font size=2>
	<input type="radio" value="1" name="ipMode" onClick="ipTypeSelection(0)">DHCP</td>
</tr>
<tr><th></th>
	<td><font size=2><b>Local IP Address:</b></td>
	<td><font size=2><input type="text" name="ip" size="10" maxlength="15"></td>
	<td><font size=2><b>Remote IP Address:</b></td>
	<td><font size=2><input type="text" name="remoteIp" size="10" maxlength="15"></td>
</tr>
<tr><th></th>
	<td><font size=2><b>Subnet Mask:</b></td>
	<td><font size=2><input type="text" name="netmask" size="10" maxlength="15"></td>
	<td><font size=2><b>IP Unnumbered</b>
		<input type="checkbox" name="ipUnnum" size="2" maxlength="2" value="ON"  onClick="ipModeSelection()"></td>
</tr>
<tr><th></th>
	<td><font size=2><b>Request DNS:</b>
		<input type="radio" value="1" name="dnsMode" onClick='dnsModeClicked()'>Enable
		<input type="radio" value="0" name="dnsMode" checked onClick='dnsModeClicked()'>Disable
	</td>
</tr>
<tr><th></th>
     <td><font size=2><b>Primary DNS Server:</b></td>
     <td><font size=2><input type="text" name="dns1" size="18" maxlength="15" value=></td>
</tr>
<tr><th></th>
     <td><font size=2><b>Secondary DNS Server:</b></td>
     <td><font size=2><input type="text" name="dns2" size="18" maxlength="15" value=></td>
</tr>
</table>

<div id='gwInfo'>
<input type="hidden"  name="gwStr">
<div id='id_dfltgwy'>
<input type="hidden"  name="dstGtwy"></div>
<input type="hidden"  name="gwStr">
<div id='id_wanIf'>
<input type="hidden"  name="wanIf"></div>
</div>


<div id=6rdDiv style="display:none"></div>

<div id=IPV6_wan_setting style="display:block">
<table id="tbipv6wan" border=0 width="800" cellspacing=4 cellpadding=0>
	<tr><td colspan=5><hr size=2 align=top></td></tr>
	<tr><th align="left"><font size=2><b>IPv6 WAN Setting:</b></th></tr>
	<tr nowrap id=TrIpv6AddrType>
		<td width="120px"><font size=2><b>Address Mode:</b></td>
		<td>
			<input type="checkbox" value="ON" name="slacc" id="send3"><font size=2><b>Slaac</b>
	        </td>
	        <td>
			<input type="checkbox" value="ON" name="staticIpv6" id="send4" onclick="ipv6StaticUpdate()"><font size=2><b>Static</b>
	        </td>
	</tr>
</table>
<div id=secIPv6Div style="display:none">
<table border=0 cellspacing=4 cellpadding=0>
	<tr id=TrIpv6Addr>
		<td width="120px"><font size=2><b>IPv6 Address:</b></td>
		<td><font size=2><input  id=Ipv6Addr maxLength=39 size=36 name=Ipv6Addr>
		/
		<font size=2><input id=Ipv6PrefixLen maxLength=3 size=3 name=Ipv6PrefixLen>
		</td>
	</tr>
	<tr id=TrIpv6Gateway>
		<td width="120px"><font size=2><b>IPv6 Gateway:</b></td>
		<td><font size=2><input  id=Ipv6Gateway  maxLength=39 size=36 name=Ipv6Gateway></td>
	</tr>
	<tr>
		<td width="120px"><font size=2><b>Primary IPv6 DNS:</b></td>
		<td><font size=2><input  maxLength=39 size=36 name=Ipv6Dns1></td>
	</tr>
		<td width="120px"><font size=2><b>Secondary IPv6 DNS:</b></td>
		<td><font size=2><input  maxLength=39 size=36 name=Ipv6Dns2></td>
	</tr>
</table>
</div>
<br>
<div  id="dhcp6c_ctrlblock"  style="display:block">
<table id="tbdhcpv6" border=0 cellspacing=4 cellpadding=0>
	<tr nowrap><td width="120px"><font size=2><b>Enable DHCPv6 Client:</b></td>
	<td><input type="checkbox" value="ON" name="itfenable" id="itfenable" onclick="dhcp6cEnable()" ></td>
	</tr>
</table>
	<div  id="dhcp6c_block"  style="display:none">
	<table  border=0 cellspacing=4 cellpadding=0>
	  <tr nowrap>
	      <td width="150px"><font size=2><b>Request Options:</b></td>
	      <td ></td>
	  </tr>
	  <tr nowrap>
	     <td width="150px"><font size=2><b>&nbsp;</b></td>
	      <td>
			<input type="checkbox" value="ON" name="iana" id="send1"><font size=2><b>Request Address</b>
	      </td>
	  </tr>
	   <tr>
	     <td width="150px"><font size=2><b>&nbsp;</b></td>
	      <td>
			<input type="checkbox" value="ON" name="iapd" id="send2"><font size=2><b>Request Prefix</b>
	      </td>
	  </tr>
	 </table>
</table>
</div>
</div>
</div>

<div id=div_pmap>
<table id=tbl_pmap border=0 width=800 cellspacing=4 cellpadding=0>
<tr><td colspan=5><hr size=2 align=top></td></tr>
<tr nowrap><td width=150px><font size=2><b>Port Mapping</b></font></td><td>&nbsp;</td></tr>
<tr nowrap><tr nowrap><td><font size=2><input type=checkbox name=chkpt>LAN_1</font></td>
</tr>
<input type=hidden name=chkpt>
<input type=hidden name=chkpt>
<input type=hidden name=chkpt>
</table>
</div>



<BR>
<input type="hidden" value="/multi_wan_generic.asp" name="submit-url">
<input type="hidden" id="lst" name="lst" value="">
<input type="hidden" name="encodePppUserName" value="">
<input type="hidden" name="encodePppPassword" value="">
<input type="submit" value="Apply Changes" name="apply" onClick="return applyCheck()">&nbsp; &nbsp; &nbsp; &nbsp;
<input type="submit" value="Delete" name="delete" onClick="return deleteCheck()">
<input type="hidden" name="itfGroup" value=0>
<BR>
<BR>
<script>
 			document.getElementById('IGMPProxy_show').style.display = 'block';


/*
	var wanmode = 7;

	if((wanmode & 1) == 1)
		document.ethwan.wmchkbox[0].checked = true;

	if((wanmode & 2) == 2)
		document.ethwan.wmchkbox[1].checked = true;

	if((wanmode & 4) == 4)
		document.ethwan.wmchkbox[2].checked = true;

	if((wanmode & 8) == 8)
		document.ethwan.wmchkbox[3].checked = true;
*/

 var isConfigRTKRG = "yes";

 if(isConfigRTKRG == "yes")
 {
  var mbt_dec = 1-1+1;

  if(mbt_dec == 1)
   document.getElementById("div_pmap").style.display = "inline";
  else
   document.getElementById("div_pmap").style.display = "none";
 }
</script>
</form>
</blockquote>
</body>
</html>
