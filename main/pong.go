/*
	Copyright (c) 2016 uAvionix
	Distributable under the terms of The "BSD New" License
	that can be found in the LICENSE file, herein included
	as part of this header.

	pong.go: uAvionix Pong ADS-B monitoring and management.
    2023 Added PongUSB MavLink support device 0403:6015
*/

package main

import (
	"bufio"
	//"fmt"
	"log"
	"os"
	"strings"
	"sync"

	//"sync/atomic"
	"net"
	"os/exec"
	"time"

	// Using forked version of tarm/serial to force Linux
	// instead of posix code, allowing for higher baud rates
	"github.com/b3nn0/stratux/common"
	"github.com/uavionix/serial"
)

// pong device data
var pongSerialConfig *serial.Config
var pongSerialPort *serial.Port
var pongWG *sync.WaitGroup
var closeChpong chan int

// 0 => pongEFB - 1090ES
// 1 => pongUSB - MavLink
var pongDeviceModel int
var pongDeviceSuccessfullyWorking bool

func initPongSerial() bool {
	var device string
	baudrate := int(2000000)

	pongDeviceModel = 0
	log.Printf("Configuring Pong ADS-B\n")

	if _, err := os.Stat("/dev/pong"); err == nil {
		device = "/dev/pong"
	} else if _, err := os.Stat("/dev/softrf"); err == nil {
		device = "/dev/softrf"
		baudrate = int(38400)
	} else {
		log.Printf("No suitable Pong device found.\n")
		return false
	}
	log.Printf("Using %s for Pong\n", device)

	// Open port
	// No timeout specified as Pong does not heartbeat
	pongSerialConfig = &serial.Config{Name: device, Baud: baudrate}
	p, err := serial.OpenPort(pongSerialConfig)
	if err != nil {
		log.Printf("Error opening serial port: %s\n", err.Error())
		return false
	}
	log.Printf("Pong opened serial port")

	// No device configuration is needed, we should be ready

	pongSerialPort = p
	return true
}

func pongNetworkRepeater() {
	defer pongWG.Done()
	log.Println("Entered Pong network repeater ...")
	cmd := exec.Command(STRATUX_HOME+"/bin/dump1090", "--net-only")
	stdout, _ := cmd.StdoutPipe()
	stderr, _ := cmd.StderrPipe()

	err := cmd.Start()
	if err != nil {
		log.Printf("Error executing "+STRATUX_HOME+"/bin/dump1090: %s\n", err)
		// don't return immediately, use the proper shutdown procedure
		shutdownPong = true
		for {
			select {
			case <-closeChpong:
				return
			default:
				time.Sleep(1 * time.Second)
			}
		}
	}

	log.Println("Executed " + cmd.String() + " successfully...")

	scanStdout := bufio.NewScanner(stdout)
	scanStderr := bufio.NewScanner(stderr)

	for {
		select {
		case <-closeChpong:
			log.Println("Pong network repeater: shutdown msg received, calling cmd.Process.Kill() ...")
			err := cmd.Process.Kill()
			if err != nil {
				log.Printf("\t couldn't kill dump1090: %s\n", err)
			} else {
				cmd.Wait()
				log.Println("\t kill successful...")
			}
			return
		default:
			for scanStdout.Scan() {
				m := Dump1090TermMessage{Text: scanStdout.Text(), Source: "stdout"}
				logDump1090TermMessage(m)
			}
			if err := scanStdout.Err(); err != nil {
				log.Printf("scanStdout error: %s\n", err)
			}

			for scanStderr.Scan() {
				m := Dump1090TermMessage{Text: scanStderr.Text(), Source: "stderr"}
				logDump1090TermMessage(m)
				if shutdownES != true {
					shutdownES = true
				}
			}
			if err := scanStderr.Err(); err != nil {
				log.Printf("scanStderr error: %s\n", err)
			}

			time.Sleep(1 * time.Second)
		}
	}
}

var dump1090ConnectionPong net.Conn = nil
var connectionErrorPong error

func pongNetworkConnection() {
	// Send to dump1090 on port 30001
	dump1090Addr := "127.0.0.1:30001"
	dump1090ConnectionPong, connectionErrorPong = net.Dial("tcp", dump1090Addr)
	// RCB monitor for connection failure and redial
}

func pongSerialReader() {
	//defer pongWG.Done()
	defer pongSerialPort.Close()
	// RCB TODO channel control for terminate

	log.Printf("Starting Pong serial reader")

	scanner := bufio.NewScanner(pongSerialPort)
	for scanner.Scan() && globalStatus.Pong_connected && globalSettings.Pong_Enabled {
		pongDeviceSuccessfullyWorking = true
		s := scanner.Text()
		// Trimspace removes newlines as well as whitespace
		s = strings.TrimSpace(s)
		//logString := fmt.Sprintf("Pong received: %s", s)
		//log.Println(logString)
		if s[0] == '*' {
			// 1090ES report
			// Pong appends a signal strength at the end of the message
			// e.g. *8DC01C2860C37797E9732E555B23;ss=049D;
			// Remove this before forwarding to dump1090
			// We currently aren't doing anything with this information
			// and need to develop a scaling equation - we're using a
			// log detector for power so it should have a logarithmic
			// relationship. In one example, at -25dBm input (upper limit
			// of RX) we saw ~0x500. At -95dBm input (lower limit of RX)
			// we saw 0x370
			report := strings.Split(s, ";")
			//replayLog(s, MSGCLASS_DUMP1090);
			if dump1090ConnectionPong == nil {
				log.Println("Starting dump1090 network connection")
				pongNetworkConnection()
			}
			if len(report[0]) != 0 && dump1090Connection != nil {
				dump1090ConnectionPong.Write([]byte(report[0] + ";\r\n"))
				//log.Println("Relaying 1090ES message")
				//logString := fmt.Sprintf("Relaying 1090ES: %s;", report[0]);
				//log.Println(logString)
			}
		} else if s[0] == '+' || s[0] == '-' {
			// UAT report
			// Pong appends a signal strength and RS bit errors corrected
			// at the end of the message
			// e.g. -08A5DFDF3907E982585F029B00040080105C3AB4BC5C240700A206000000000000003A13C82F96C80A63191F05FCB231;rs=1;ss=A2;
			// We need to rescale the signal strength for interpretation by dump978,
			// which expects a 0-1000 base 10 (linear?) scale
			// RSSI is in hex and represents an int8 with -128 (0x80) representing an
			// errored measurement. There will be some offset from actual due to loss
			// in the path. In one example we measured 0x93 (-98) when injecting a
			// -102dBm signal
			o, msgtype := parseInput(s)
			if o != nil && msgtype != 0 {
				//logString = fmt.Sprintf("Relaying message, type=%d", msgtype)
				//log.Println(logString)
				relayMessage(msgtype, o)
			} else if o == nil {
				//log.Println("Not relaying message, o == nil")
			} else {
				//log.Println("Not relaying message, msgtype == 0")
			}
		}
	}
	globalStatus.Pong_connected = false
	log.Printf("Exiting Pong serial reader")
	return
}

func pongShutdown() {
	log.Println("Entered Pong shutdown() ...")
	//close(closeChpong)
	//log.Println("Pong shutdown(): calling pongWG.Wait() ...")
	//pongWG.Wait() // Wait for the goroutine to shutdown
	//log.Println("Pong shutdown(): pongWG.Wait() returned...")
	// Serial Port Gracefully Close and Read() returns
	//globalStatus.Pong_connected = false
	if globalStatus.Pong_connected == true {
		pongSerialPort.Close()
	}
}

func pongKill() {
	// Send signal to shutdown to pongWatcher().
	shutdownPong = true
	// Spin until device has been de-initialized.
	for globalStatus.Pong_connected != false {
		time.Sleep(1 * time.Second)
	}
}

// to keep our sync primitives synchronized, only exit a read
// method's goroutine via the close flag channel check, to
// include catastrophic dongle failures
var shutdownPong bool

// Watch for config/device changes.
func pongWatcher() {
	prevPongEnabled := false
	pongDeviceSuccessfullyWorking = false

	for {
		time.Sleep(1 * time.Second)

		// true when a serial call fails
		if shutdownPong {
			pongShutdown()
			shutdownPong = false
			// Shutdown this reconnection loop
			break
		}
		// Autoreconnect the device
		if pongDeviceSuccessfullyWorking == true && globalSettings.Pong_Enabled && !globalStatus.Pong_connected {
			prevPongEnabled = false
		}

		if prevPongEnabled == globalSettings.Pong_Enabled {
			continue
		}

		// Global settings have changed, reconfig
		if globalSettings.Pong_Enabled && !globalStatus.Pong_connected {
			globalStatus.Pong_connected = initPongSerial()
			// This will retry next loop to connect again to the device
			if globalStatus.Pong_connected == false {
				// Relaxed polling to wait the device to be discovered
				time.Sleep(10 * time.Second)
				continue
			}
			//count := 0
			// pongEFB - 1090
			if globalStatus.Pong_connected && pongDeviceModel == 0 {
				//pongWG.Add(1)
				go pongNetworkRepeater()
				//pongNetworkConnection()
				go pongSerialReader()
				// Emulate SDR count
				//count = 2
			}
			// pongUSB - MavLink
			if globalStatus.Pong_connected && pongDeviceModel == 1 {
				go pongUSBSerialReader()
			}
			//atomic.StoreUint32(&globalStatus.Devices, uint32(count))
		} else if !globalSettings.Pong_Enabled {
			pongShutdown()
		}

		prevPongEnabled = globalSettings.Pong_Enabled
	}
}

func pongInit() {
	go pongWatcher()
}

type MavlinkTrafficMessageFormatPong struct {
	ICAO_address  uint32
	lat           int32
	lon           int32
	altitude      int32
	heading       uint16
	hor_velocity  uint16
	ver_velocity  int16
	validFlags    uint16
	squawk        uint16
	altitude_type uint8
	callsign      [9]byte
	emitter_type  uint8
	tslc          uint8
}

func mavLinkFormatPong(x []byte) {
	msglenMavLink := x[1]
	msgtypeMavLink := x[5]
	if msgtypeMavLink == 246 && msglenMavLink >= 38 {
		mavLink := MavlinkTrafficMessageFormatPong{}
		pongUsbHeaderLen := 6
		pongUsbHeaderCursor := 0
		mavLink.ICAO_address = uint32(x[3+pongUsbHeaderLen+pongUsbHeaderCursor])<<24 | uint32(x[2+pongUsbHeaderLen+pongUsbHeaderCursor])<<16 | uint32(x[1+pongUsbHeaderLen+pongUsbHeaderCursor])<<8 | uint32(x[0+pongUsbHeaderLen+pongUsbHeaderCursor])
		pongUsbHeaderCursor = 4
		mavLink.lat = int32(uint32(x[3+pongUsbHeaderLen+pongUsbHeaderCursor])<<24 | uint32(x[2+pongUsbHeaderLen+pongUsbHeaderCursor])<<16 | uint32(x[1+pongUsbHeaderLen+pongUsbHeaderCursor])<<8 | uint32(x[0+pongUsbHeaderLen+pongUsbHeaderCursor]))
		pongUsbHeaderCursor = 8
		mavLink.lon = int32(uint32(x[3+pongUsbHeaderLen+pongUsbHeaderCursor])<<24 | uint32(x[2+pongUsbHeaderLen+pongUsbHeaderCursor])<<16 | uint32(x[1+pongUsbHeaderLen+pongUsbHeaderCursor])<<8 | uint32(x[0+pongUsbHeaderLen+pongUsbHeaderCursor]))
		pongUsbHeaderCursor = 12
		mavLink.altitude = int32(uint32(x[3+pongUsbHeaderLen+pongUsbHeaderCursor])<<24 | uint32(x[2+pongUsbHeaderLen+pongUsbHeaderCursor])<<16 | uint32(x[1+pongUsbHeaderLen+pongUsbHeaderCursor])<<8 | uint32(x[0+pongUsbHeaderLen+pongUsbHeaderCursor]))
		pongUsbHeaderCursor = 16
		mavLink.heading = (uint16(x[1+pongUsbHeaderLen+pongUsbHeaderCursor])<<8 | uint16(x[0+pongUsbHeaderLen+pongUsbHeaderCursor]))
		pongUsbHeaderCursor = 18
		mavLink.hor_velocity = (uint16(x[1+pongUsbHeaderLen+pongUsbHeaderCursor])<<8 | uint16(x[0+pongUsbHeaderLen+pongUsbHeaderCursor]))
		pongUsbHeaderCursor = 20
		mavLink.ver_velocity = int16(uint16(x[1+pongUsbHeaderLen+pongUsbHeaderCursor])<<8 | uint16(x[0+pongUsbHeaderLen+pongUsbHeaderCursor]))
		pongUsbHeaderCursor = 22
		mavLink.validFlags = (uint16(x[1+pongUsbHeaderLen+pongUsbHeaderCursor])<<8 | uint16(x[0+pongUsbHeaderLen+pongUsbHeaderCursor]))
		pongUsbHeaderCursor = 24
		mavLink.squawk = (uint16(x[1+pongUsbHeaderLen+pongUsbHeaderCursor])<<8 | uint16(x[0+pongUsbHeaderLen+pongUsbHeaderCursor]))
		pongUsbHeaderCursor = 26
		mavLink.altitude_type = x[0+pongUsbHeaderLen+pongUsbHeaderCursor]
		pongUsbHeaderCursor = 27

		for j := 0; j < 9; j++ {
			mavLink.callsign[j] = 0
		}
		for a, b := range x[0+pongUsbHeaderLen+pongUsbHeaderCursor:] {
			if a > 8 || b == ' ' {
				break
			}
			mavLink.callsign[a] = b
		}
		pongUsbHeaderCursor = 36
		mavLink.emitter_type = x[0+pongUsbHeaderLen+pongUsbHeaderCursor]
		pongUsbHeaderCursor = 37
		mavLink.tslc = x[0+pongUsbHeaderLen+pongUsbHeaderCursor]
		if globalSettings.DEBUG {
			log.Printf("ICAO_address %06X lat: %d lon: %d alt: %d head: %d call: %s vspeed: %d speed: %d", mavLink.ICAO_address, mavLink.lat, mavLink.lon, mavLink.altitude, mavLink.heading, mavLink.callsign, mavLink.ver_velocity, mavLink.hor_velocity)
		}
		var ti TrafficInfo
		trafficMutex.Lock()
		signalLevelSimulated := -1
		if val, ok := traffic[mavLink.ICAO_address]; ok { // if we've already seen it, copy it in to do updates as it may contain some useful information like "tail" from 1090ES.
			ti = val
		} else {
			// New
			ti.Last_seen = stratuxClock.Time
		}
		if mavLink.heading != 0 {
			ti.Track = float32(mavLink.heading / 100)
		} else {
			signalLevelSimulated -= 5
		}
		ti.ReceivedMsgs += 1
		ti.Icao_addr = mavLink.ICAO_address
		ti.OnGround = false
		ti.Addr_type = 0
		if mavLink.squawk != 0 {
			ti.Squawk = int(mavLink.squawk)
		}
		ti.TargetType = TARGET_TYPE_ADSB
		if mavLink.emitter_type != 0 {
			ti.Emitter_category = uint8(mavLink.emitter_type)
		}
		if mavLink.lat != 0 && mavLink.lon != 0 {
			lat := float32(mavLink.lat) / 10000000.0
			lng := float32(mavLink.lon) / 10000000.0
			// Low signal may involve into a freeze location, update only if it really changes
			if lng != ti.Lng && lat != ti.Lat {
				ti.Lat = lat
				ti.Lng = lng
				if isGPSValid() {
					lat := float64(mySituation.GPSLatitude)
					lng := float64(mySituation.GPSLongitude)
					ti.Distance, ti.Bearing = common.Distance(float64(lat), float64(lng), float64(ti.Lat), float64(ti.Lng))
					ti.BearingDist_valid = true
				} else {
					ti.BearingDist_valid = false
				}
				ti.Position_valid = true
				ti.ExtrapolatedPosition = false
				ti.Last_seen = stratuxClock.Time
				ti.Timestamp = time.Now().UTC()
			}
		} else {
			ti.Position_valid = false
			signalLevelSimulated -= 5
		}
		altitudeFoot := int32(float32(mavLink.altitude) / 304.8)
		if altitudeFoot > 0 && altitudeFoot < 70000 {
			// Low signal may involve into a freeze location, update only if it really changes
			if ti.Alt != altitudeFoot {
				ti.Alt = altitudeFoot
				ti.Last_alt = stratuxClock.Time
				ti.Last_seen = stratuxClock.Time
				ti.Timestamp = time.Now().UTC()
			}
		} else {
			signalLevelSimulated -= 5
		}
		if mavLink.altitude_type > 0 {
			ti.AltIsGNSS = true
		}
		if mavLink.hor_velocity > 0 {
			ti.Speed = uint16(float32(mavLink.hor_velocity) * 36 / 1852)
			ti.Speed_valid = true
			ti.Last_speed = stratuxClock.Time
		} else {
			ti.Speed_valid = false
			signalLevelSimulated -= 5
		}
		ti.Vvel = int16(float32(mavLink.ver_velocity) * 60.0 / 10.0 / 3.048)
		var callsignLen = 0
		for a, b := range mavLink.callsign {
			if b == ' ' || b == '\u0000' {
				break
			}
			callsignLen = a + 1
		}
		thisReg, validReg := icao2reg(ti.Icao_addr)
		if validReg {
			ti.Reg = thisReg
		}
		if callsignLen > 0 {
			ti.Tail = string(mavLink.callsign[:callsignLen])
		} else {
			signalLevelSimulated -= 5
			if validReg {
				ti.Tail = thisReg
			}
		}
		// Timestamp and Last_seen are updated only if Location or Altitude changes
		ti.NACp = 8
		ti.NIC = 8
		ti.Last_source = TRAFFIC_SOURCE_1090ES
		ti.SignalLevel = float64(signalLevelSimulated)
		postProcessTraffic(&ti)
		traffic[ti.Icao_addr] = ti
		registerTrafficUpdate(ti)
		seenTraffic[ti.Icao_addr] = true
		trafficMutex.Unlock()
	}
}

func mavLinkParsePong(mavLinkFrame []byte) bool {
	if mavLinkFrame[0] != 0xfe || len(mavLinkFrame) > 1024 {
		return true
	}
	if len(mavLinkFrame) < 9 || mavLinkFrame[0] != 0xfe || int(mavLinkFrame[1]+8) != len(mavLinkFrame) {
		return false
	}
	mavLinkFormatPong(mavLinkFrame)
	pongDeviceSuccessfullyWorking = true
	return true
}

func pongUSBSerialReader() {
	defer pongSerialPort.Close()
	// RCB TODO channel control for terminate
	log.Printf("Starting PongUSB serial reader")
	data := make([]byte, 4096)
	mavLinkFrame := make([]byte, 4096)
	mavLinkFrameLastIndex := 0
	for globalStatus.Pong_connected && globalSettings.Pong_Enabled {
		n, err := pongSerialPort.Read(data)
		if err != nil {
			break
		}
		for _, b := range data[:n] {
			if b == 0xfe && mavLinkFrameLastIndex > 0 {
				if mavLinkFrameLastIndex > 0 {
					if mavLinkParse(mavLinkFrame[:mavLinkFrameLastIndex]) {
						mavLinkFrameLastIndex = 0
					}
					mavLinkFrame[mavLinkFrameLastIndex] = b
					mavLinkFrameLastIndex += 1
				}
			} else {
				mavLinkFrame[mavLinkFrameLastIndex] = b
				mavLinkFrameLastIndex += 1
			}
		}
		continue
	}
	globalStatus.Pong_connected = false
	log.Printf("Exiting PongUSB serial reader")
	return
}
