#!/bin/bash

ME="$(basename "${BASH_ARGV0}")"

# This EXIT code is also defined in variables.sh, but in case we can't open that file, we need it here.
EXIT_ERROR_STOP=100		# unrecoverable error - need user action so stop service

# Make it easy to find the beginning of this run in the log file.
echo "     ***** Starting AllSky *****"

if [[ -z ${ALLSKY_HOME} ]]; then
	ALLSKY_HOME="$(realpath "$(dirname "${BASH_ARGV0}")")"
	export ALLSKY_HOME
fi
cd "${ALLSKY_HOME}" || exit 1

NOT_STARTED_MSG="Unable to start Allsky!"
STOPPED_MSG="Allsky Stopped!"
ERROR_MSG_PREFIX="*** ERROR ***\n${STOPPED_MSG}\n"

source "${ALLSKY_HOME}/variables.sh"	|| exit 99
if [[ -z ${ALLSKY_CONFIG} ]]; then
	MSG="FATAL ERROR: unable to source variables.sh."
	echo -e "${RED}*** ${MSG}${NC}"
	doExit "${EXIT_ERROR_STOP}" "Error" \
		"${ERROR_MSG_PREFIX}\n$(basename "${ALLSKY_HOME}")/variables.sh\nis corrupted." \
		"${NOT_STARTED_MSG}<br>${MSG}"
fi
source "${ALLSKY_CONFIG}/config.sh"		|| exit $?		# it displays any error message
source "${ALLSKY_SCRIPTS}/functions.sh" || exit $?		# it displays any error message
SEE_LOG_MSG="See ${ALLSKY_LOG}"
ARGS_FILE="${ALLSKY_TMP}/capture_args.txt"

# This file contains information the user needs to act upon after an installation.
# If the file exists, display it and stop.
if [[ -f ${POST_INSTALLATION_ACTIONS} ]]; then
	mv "${POST_INSTALLATION_ACTIONS}" "${ALLSKY_TMP}"	# in case the user wants to look at it later
	echo "${POST_INSTALLATION_ACTIONS} moved to ${ALLSKY_TMP}"
	# There should already be a message so don't add another,
	# and there's already an image, so don't overwrite it.
	# shellcheck disable=SC2154
	doExit "${EXIT_ERROR_STOP}" "no-image" "" "See ${ALLSKY_TMP}/${POST_INSTALLATION_ACTIONS}"
fi

# COMPATIBILITY CHECKS
# Check for a new variable in config.sh that wasn't in prior versions.
# If not set to something (even "") then it wasn't found and force the user to upgrade config.sh
if [[ ! -v WEBUI_DATA_FILES ]]; then	# WEBUI_DATA_FILES added after version 0.8.3.
	MSG="FATAL ERROR: old version of ${ALLSKY_CONFIG}/config.sh detected."
	echo -e "${RED}*** ${MSG}${ALLSKY_CONFIG}/config.sh detected.${NC}"
	echo "Please move your current config.sh file to config.sh-OLD, then place the newest one"
	echo "from https://github.com/thomasjacquin/allsky in ${ALLSKY_CONFIG} and"
	echo "manually copy your data from the old file to the new one."
	doExit "${EXIT_ERROR_STOP}" "Error" \
		"${ERROR_MSG_PREFIX}\n$(basename "${ALLSKY_CONFIG}")/config.sh\nis an old version.  See\n${ALLSKY_LOG}" \
		"${NOT_STARTED_MSG}<br>${MSG}<br>${SEE_LOG_MSG}."

fi
USE_NOTIFICATION_IMAGES=$(settings ".notificationimages")

if [[ -z ${CAMERA_TYPE} ]]; then
	MSG="FATAL ERROR: 'Camera Type' not set in WebUI."
	echo -e "${RED}*** ${MSG}${NC}"
	doExit "${EXIT_NO_CAMERA}" "Error" \
		"${ERROR_MSG_PREFIX}\nCamera Type\nnot specified\nin the WebUI." \
		"${NOT_STARTED_MSG}<br>${MSG}"
fi

# Make sure we are not already running.
pgrep "${ME}" | grep -v $$ | xargs "sudo kill -9" 2>/dev/null

if [[ ${CAMERA_TYPE} == "RPi" ]]; then
	# "true" means use doExit() on error
	RPi_COMMAND_TO_USE="$(determineCommandToUse "true" "${ERROR_MSG_PREFIX}" )"

elif [[ ${CAMERA_TYPE} == "ZWO" ]]; then
	RESETTING_USB_LOG="${ALLSKY_TMP}/resetting_USB.txt"
	reset_usb()		# resets the USB bus
	{
		REASON="${1}"		# why are we resetting the bus?
		# Only reset a couple times, then exit with fatal error.
		typeset -i COUNT
		if [[ -f ${RESETTING_USB_LOG} ]]; then
			COUNT=$(< "${RESETTING_USB_LOG}")
		fi
		COUNT=${COUNT:-0}
		if [[ ${COUNT} -eq 2 ]]; then
			MSG="FATAL ERROR: Too many consecutive USB bus resets done (${COUNT})."
			echo -e "${RED}*** ${MSG} Stopping." >&2
			rm -f "${RESETTING_USB_LOG}"
			doExit "${EXIT_ERROR_STOP}" "Error" \
				"${ERROR_MSG_PREFIX}\nToo many consecutive\nUSB bus resets done!\n${SEE_LOG_MSG}" \
				"${NOT_STARTED_MSG}<br>${MSG}"
		fi

		if [[ ${ON_TTY} -eq 1 ]]; then
			echo "${YELLOW}WARNING: Resetting USB ports ${REASON/\\n/ }; restart ${ME} when done.${NC}" >&2
		else
			echo "${YELLOW}WARNING: Resetting USB ports ${REASON/\\n/ }, then restarting.${NC}" >&2
			# The service will automatically restart this script.
		fi

		((COUNT=COUNT+1))
		echo "${COUNT}" > "${RESETTING_USB_LOG}"

		# Display a warning message
		"${ALLSKY_SCRIPTS}/generate_notification_images.sh" --directory "${ALLSKY_TMP}" "${FILENAME}" \
			"yellow" "" "85" "" "" \
			"" "5" "yellow" "${EXTENSION}" "" "WARNING:\n\nResetting USB bus\n${REASON}.\nAttempt ${COUNT}."
		sudo "$UHUBCTL_PATH" -a cycle -l "$UHUBCTL_PORT"
		sleep 3		# give it a few seconds, plus, allow the notification images to be seen
	}

	# Use two commands to better aid debugging when camera isn't found.
	ZWOdev=$(lsusb -d '03c3:' | awk '{ bus=$2; dev=$4; gsub(/[^0-9]/,"",dev); print "/dev/bus/usb/"bus"/"dev;}')
	ZWOIsPresent=$(lsusb -D "${ZWOdev}" 2>/dev/null | grep -c 'iProduct .*ASI[0-9]')
	if [[ $ZWOIsPresent -eq 0 ]]; then
		if [[ -n ${UHUBCTL_PATH} ]] ; then
			reset_usb "looking for a\nZWO camera"		# reset_usb exits if too many tries
			exit 0	# exit with 0 so the service is restarted
		else
			MSG="FATAL ERROR: ZWO Camera not found"
			echo -en "${RED}*** ${MSG}" >&2
			if [[ $ZWOdev == "" ]]; then
				echo " and no USB entry either.${NC}" >&2
				USB_MSG=""
			else
				echo " but $ZWOdev found.${NC}" >&2
				USB_MSG="\n${SEE_LOG_MSG}"
			fi

			echo "  If you have the 'uhubctl' command installed, add it to config.sh." >&2
			echo "  In the meantime, try running it to reset the USB bus." >&2
			doExit "${EXIT_NO_CAMERA}" "Error" \
				"${ERROR_MSG_PREFIX}\nNo ZWO camera\nfound!${USB_MSG}" \
				"${NOT_STARTED_MSG}<br>${MSG}<br>${SEE_LOG_MSG}."
		fi
	fi

	rm -f "${RESETTING_USB_LOG}"	# We found the camera so don't need to reset.

else
	MSG="FATAL ERROR: Unknown Camera Type: ${CAMERA_TYPE}."
	echo -e "${RED}${MSG}  Stopping.${NC}" >&2
	doExit "${EXIT_NO_CAMERA}" "Error" \
		"${ERROR_MSG_PREFIX}\nUnknown Camera\nType: ${CAMERA_TYPE}" \
		"${NOT_STARTED_MSG}<br>${MSG}"
fi

echo "CAMERA_TYPE: ${CAMERA_TYPE}"

if [[ -d ${ALLSKY_TMP} ]]; then
	# remove any lingering old image files.
	rm -f "${ALLSKY_TMP}/${FILENAME}"-202*."${EXTENSION}"	# "202" for 2020 and later
else
	# We should never get here since ${ALLSKY_TMP} is created during installation...
	mkdir -p "${ALLSKY_TMP}"
	chmod 775 "${ALLSKY_TMP}"
	sudo chgrp www-data "${ALLSKY_TMP}"
fi

# Clear out this file and allow the web server to write to it.
: > "${ALLSKY_ABORTEDUPLOADS}"
sudo chgrp www-data "${ALLSKY_ABORTEDUPLOADS}"
sudo chmod 664 "${ALLSKY_ABORTEDUPLOADS}"

# Create tmp/extra directory.
[[ ! -d "${ALLSKY_TMP}/extra" ]] && mkdir "${ALLSKY_TMP}/extra"

# Optionally display a notification image.
if [[ $USE_NOTIFICATION_IMAGES -eq 1 ]]; then
	# Can do this in the background to speed up startup
	"${ALLSKY_SCRIPTS}/copy_notification_image.sh" "StartingUp" 2>&1 &
fi

: > "${ARGS_FILE}"
if [[ ${CAMERA_TYPE} == "RPi" ]]; then
	# This argument needs to come first since the capture code checks for it first.
	echo "-cmd=${RPi_COMMAND_TO_USE}" >> "${ARGS_FILE}"
fi

# This argument should come second so the capture program knows if it should display debug output.
echo "-debuglevel=${ALLSKY_DEBUG_LEVEL}" >> "${ARGS_FILE}"
echo "-version=$(< "${ALLSKY_HOME}/version")" >> "${ARGS_FILE}"

# shellcheck disable=SC2207
KEYS=( $(settings 'keys[]') )
for KEY in "${KEYS[@]}"
do
	K="$(settings ".${KEY}")"
	# We have to pass "-config ${ARGS_FILE}" on the command line,
	# and debuglevel we did above.
	[[ ${KEY} != "config" && ${KEY} != "debuglevel" ]] && echo "-${KEY}=${K}" >> "${ARGS_FILE}"
done

# When using a desktop environment a preview of the capture can be displayed in a separate window.
# The preview mode does not work if we are started as a service or if the debian distribution has no desktop environment.
[[ $1 == "preview" ]] && echo "-preview=1" >> "${ARGS_FILE}"

echo "-save_dir=${CAPTURE_SAVE_DIR}" >> "${ARGS_FILE}"

FREQUENCY_FILE="${ALLSKY_TMP}/IMG_UPLOAD_FREQUENCY.txt"
# If the user wants images uploaded only every n times, save that number to a file.
if [[ ${IMG_UPLOAD_FREQUENCY} -ne 1 ]]; then
	# Save "1" so we upload the first image.
	# saveImage.sh will write ${IMG_UPLOAD_FREQUENCY} to the file as needed.
	echo "1" > "${FREQUENCY_FILE}"
else
	rm -f "${FREQUENCY_FILE}"
fi

CAPTURE="capture_${CAMERA_TYPE}"

rm -f "${ALLSKY_NOTIFICATION_LOG}"	# clear out any notificatons from prior runs.

# Run the main program - this is the main attraction...
# Pass debuglevel on command line so the capture program knows if it should display debug output.
"${ALLSKY_BIN}/${CAPTURE}" -debuglevel "${ALLSKY_DEBUG_LEVEL}" -config "${ARGS_FILE}"
RETCODE=$?

[[ ${RETCODE} -eq ${EXIT_OK} ]] && doExit "${EXIT_OK}" ""

if [[ ${RETCODE} -eq ${EXIT_RESTARTING} ]]; then
	if [[ ${ON_TTY} -eq 1 ]]; then
		echo "*** Can restart allsky now. ***"
		NOTIFICATION_TYPE="NotRunning"
	else
		NOTIFICATION_TYPE="Restarting"
	fi
	doExit 0 "${NOTIFICATION_TYPE}"		# use 0 so the service is restarted
fi

if [[ ${RETCODE} -eq ${EXIT_RESET_USB} ]]; then
	# Reset the USB bus if possible
	if [[ ${UHUBCTL_PATH} != "" ]]; then
		reset_usb " (ASI_ERROR_TIMEOUTs)"
		if [[ ${ON_TTY} -eq 1 ]]; then
			echo "*** USB bus was reset; You can restart allsky now. ***"
			NOTIFICATION_TYPE="NotRunning"
		else
			NOTIFICATION_TYPE="Restarting"
		fi
		if [[ ${USE_NOTIFICATION_IMAGES} -eq 1 ]]; then
			"${ALLSKY_SCRIPTS}/copy_notification_image.sh" "${NOTIFICATION_TYPE}"
		fi
		doExit 0 ""		# use 0 so the service is restarted
	else
		# TODO: use ASI_ERROR_TIMEOUT message
		MSG="Non-recoverable ERROR found"
		[[ ${ON_TTY} -eq 1 ]] && echo "*** ${MSG} - ${SEE_LOG_MSG}. ***"
		doExit "${EXIT_ERROR_STOP}" "Error" \
			"${ERROR_MSG_PREFIX}Too many\nASI_ERROR_TIMEOUT\nerrors received!\n${SEE_LOG_MSG}" \
			"${STOPPED_MSG}<br>${MSG}<br>${SEE_LOG_MSG}."
	fi
fi

# RETCODE -ge ${EXIT_ERROR_STOP} means we should not restart until the user fixes the error.
if [[ ${RETCODE} -ge ${EXIT_ERROR_STOP} ]]; then
	echo "***"
	if [[ ${ON_TTY} -eq 1 ]]; then
		echo "*** After fixing, restart ${ME}.sh. ***"
	else
		echo "*** After fixing, restart the allsky service. ***"
	fi
	echo "***"
	doExit "${EXIT_ERROR_STOP}" "Error"	# Can't do a custom message since we don't know the problem
fi

# Some other error
if [[ ${USE_NOTIFICATION_IMAGES} -eq 1 ]]; then
	# If started by the service, it will restart us once we exit.
	doExit "${RETCODE}" "NotRunning"
else
	doExit "${RETCODE}" ""
fi
