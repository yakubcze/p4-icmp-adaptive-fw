/* -*- P4_16 -*- */
#include <core.p4>
#include <v1model.p4>

const bit<16> TYPE_IPV4 = 0x800;

const bit<8> ICMP = 0x01;
const bit<8> ICMP_ECHO_REPLY = 0x00;
const bit<8> ICMP_ECHO_REQUEST = 0x08;

/*************************************************************************
*********************** H E A D E R S  ***********************************
*************************************************************************/

typedef bit<9>  egressSpec_t;
typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;

header ethernet_t {
    macAddr_t dstAddr;
    macAddr_t srcAddr;
    bit<16>   etherType;
}

struct metadata {
    bit<32> meter_tag;
}

header ipv4_t {
    bit<4>    version;
    bit<4>    ihl;
    bit<8>    diffserv;
    bit<16>   totalLen;
    bit<16>   identification;
    bit<3>    flags;
    bit<13>   fragOffset;
    bit<8>    ttl;
    bit<8>    protocol; //0x01 = ICMP
    bit<16>   hdrChecksum;
    ip4Addr_t srcAddr;
    ip4Addr_t dstAddr;
}

header icmp_t {
    bit<8>    type;
    bit<8>    code; //0x00 = echo reply, 0x08 = echo request
    bit<16>   checksum;
    bit<32>   unused;
}

struct headers {
    ethernet_t   ethernet;
    ipv4_t       ipv4;
    icmp_t       icmp;
}

/*************************************************************************
*********************** P A R S E R  ***********************************
*************************************************************************/

parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {

    state start {
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_IPV4: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol){
            ICMP: parse_icmp;
            default: accept;
        }
    }

    //parsovani ICMP, potrebujeme pole "code" viz. vyse
    state parse_icmp {
        packet.extract(hdr.icmp);
            transition accept;
        }
    }


/*************************************************************************
************   C H E C K S U M    V E R I F I C A T I O N   *************
*************************************************************************/

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply {  }
}


/*************************************************************************
**************  I N G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {

    counter(512, CounterType.packets_and_bytes) port_counter;   //pocitadlo vsech packetu
    counter(512, CounterType.packets_and_bytes) icmp_counter;   //pocitadlo icmp packetu

    action drop() {
        mark_to_drop(standard_metadata);
    }

    action ipv4_forward(macAddr_t dstAddr, egressSpec_t port) {
        standard_metadata.egress_spec = port;
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
        port_counter.count((bit<32>)standard_metadata.ingress_port);
    }

    action icmp_process() { //akce pro zpracovani icmp
         icmp_counter.count(1); //inkrementuje counter na indexu 1 o hodnotu pruchozich packetu a bytu
    }

    table ipv4_lpm {
        key = {
            hdr.ipv4.dstAddr: lpm;  //lpm = longest prefix match, matchujeme IP/masku s nejdelsi shodou
        }
        actions = {
            ipv4_forward;
            drop;
            NoAction;
        }
        size = 1024;
        default_action = drop();
    }

    table icmp_match {
        key = {
            hdr.ipv4.protocol: exact;  //matchujeme konkretni hodnotu
        }
        actions = {
            icmp_process;
            drop;
            NoAction;
        }
        size = 1;
        default_action = drop();
    }

    

    apply {
        if (hdr.ipv4.isValid()) {
            if(hdr.ipv4.protocol == ICMP) {  //if hodnota pole "protocol" v IP zahlavi == 0x01 => zajima nas jenom ICMP
                if(hdr.icmp.type == ICMP_ECHO_REPLY){  //if hodnota pole "type" v ICMP zahlavi == 0x00 => zajima nas pouze ICMP ECHO REPLY
                    icmp_match.apply(); //aplikujeme tabulku "icmp_match" => (pouze se provede inkrementace counteru)
                }
            }
            ipv4_lpm.apply(); //routing
        }
    }
}

/*************************************************************************
****************  E G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {
    apply {  }
}

/*************************************************************************
*************   C H E C K S U M    C O M P U T A T I O N   **************
*************************************************************************/

control MyComputeChecksum(inout headers  hdr, inout metadata meta) {
     apply {
        update_checksum(
        hdr.ipv4.isValid(),
            { hdr.ipv4.version,
              hdr.ipv4.ihl,
              hdr.ipv4.diffserv,
              hdr.ipv4.totalLen,
              hdr.ipv4.identification,
              hdr.ipv4.flags,
              hdr.ipv4.fragOffset,
              hdr.ipv4.ttl,
              hdr.ipv4.protocol,
              hdr.ipv4.srcAddr,
              hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}

/*************************************************************************
***********************  D E P A R S E R  *******************************
*************************************************************************/

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.icmp); //nutno pridat tento radek, jinak by se nevlozil ICMP do odchoziho packetu => neodeslalo by se vubec nic protoze by nesedel checksum (viz. pcap)
    }
}

/*************************************************************************
***********************  S W I T C H  *******************************
*************************************************************************/

V1Switch(
MyParser(),
MyVerifyChecksum(),
MyIngress(),
MyEgress(),
MyComputeChecksum(),
MyDeparser()
) main;
