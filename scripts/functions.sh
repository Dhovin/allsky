#!/bin/bash

# Shell functions used by multiple scripts.
# This file is "source"d into others, and must be done AFTER source'ing variables.sh
# and config.sh.


# Exit with error message and a custom notification image.
function doExit()
{
	EXITCODE=$1
	TYPE=${2:-"Error"}
	CUSTOM_MESSAGE="${3}"

	if [ ${EXITCODE} -ge ${EXIT_ERROR_STOP} ]; then
		# With fatal EXIT_ERROR_STOP errors, we can't continue so display a notification image
		# even if the user has them turned off.
		if [ -n "${CUSTOM_MESSAGE}" ]; then
			# Create a custom error message.
			# If we error out before config.sh is sourced in, $FILENAME and $EXTENSION won't be
			# set so guess at what they are.
			"${ALLSKY_SCRIPTS}/generate_notification_images.sh" --directory "${ALLSKY_TMP}" "${FILENAME:-"image"}" \
				"red" "" "85" "" "" \
				"" "10" "red" "${EXTENSION:-"jpg"}" "" "${CUSTOM_MESSAGE}"
		else
			"${ALLSKY_SCRIPTS}/copy_notification_image.sh" --expires 0 "${TYPE}" 2>&1
		fi
		# Don't let the service restart us because we'll likely get the same error again.
		echo "     ***** AllSky Stopped *****"
		sudo systemctl stop allsky
	fi
	exit ${EXITCODE}
}


# RPi cameras can use either "raspistill" on Buster or "libcamera-still" on Bullseye
# to actually take pictures.
# Determine which to use.
# On success, return 1 and the command to use.
# On failure, return 0 and an error message.
function determineCommandToUse()
{
	USE_doExit="${1}"			# Call doExit() on error?
	PREFIX="${2}"				# only used if calling doExit()

	# If libcamera is installed and works, use it.
	# If it's not installed, or IS installed but doesn't work (the user may not have it configured),
	# use raspistill.

	CMD="libcamera-still"
	if command -v ${CMD} > /dev/null; then
		# Found the command - see if it works.
		"${CMD}" --timeout 1 --nopreview > /dev/null 2>&1
		RET=$?
	fi

	if [ ${RET} -ne 0 ]; then
		# Didn't find libcamera-still, or it didn't work.

		CMD="raspistill"
		if ! command -v "${CMD}" > /dev/null; then
			echo -e "${RED}*** ERROR: Can't determine what command to use for RPi camera.${NC}"
			if [[ ${USE_doExit} == "true" ]]; then
				doExit ${EXIT_ERROR_STOP} "Error" "${PREFIX}\nRPi camera command\nnot found!."
			fi

			return 1
		fi

		# TODO: Should try and run raspistill command - doing that is more reliable since
		# the output of vcgencmd changes depending on the OS and how the Pi is configured.
		# Newer kernels/libcamera give:   supported=1 detected=0, libcamera interfaces=1
		# but only if    start_x=1    is in /boot/config.txt
		vcgencmd get_camera | grep --silent "supported=1" ######### detected=1"
		RET=$?
	fi

	if [ ${RET} -ne 0 ]; then
		echo -e "${RED}*** ERROR: RPi camera not found.  Make sure it's enabled.${NC}"
		if [[ ${USE_doExit} == "true" ]]; then
			doExit ${EXIT_NO_CAMERA} "Error" "${PREFIX}\nRPi camera\nnot found!\nMake sure it's enabled."
		fi

		return 1
	fi

	echo "${CMD}"
	return 0
}


# Display a message of various types in appropriate colors.
# Used primarily in installation scripts.
display_msg()
{
	if [[ $1 == "--log" ]]; then
		LOG_IT_=true
		shift
	else
		LOG_IT_=false
	fi

	LOG_TYPE_="${1}"
	MESSAGE_="${2}"
	MSG_=""
	if [[ ${LOG_TYPE_} == "error" ]]; then
		MSG_="\n${RED}*** ERROR: "
		STARS_=true

	elif [[ ${LOG_TYPE_} == "warning" ]]; then
		MSG_="\n${YELLOW}*** WARNING: "
		STARS_=true

	elif [[ ${LOG_TYPE_} == "progress" ]]; then
		MSG_="${GREEN}* ${MESSAGE_}${NC}"
		STARS_=false

	elif [[ ${LOG_TYPE_} == "info" ]]; then
		MSG_="${YELLOW}${MESSAGE_}${NC}"
		STARS_=false

	else
		MSG_="${YELLOW}"
		STARS_=false
	fi

	if [[ ${STARS_} == "true" ]]; then
		MSG_="${MSG_}**********\n"
		MSG_="${MSG_}${MESSAGE_}\n"
		MSG_="${MSG_}**********${NC}\n"
	fi

	# Log messages to a file if it was specified.
	# ${DISPLAY_MSG_LOG} <should> be set if ${LOG_IT} is true, but just in case, check.
	if [[ ${LOG_IT_} == "true" && -n ${DISPLAY_MSG_LOG} ]]; then
		echo -e "${MSG_}" | tee -a "${DISPLAY_MSG_LOG}"
	else
		echo -e "${MSG_}"
	fi
}
