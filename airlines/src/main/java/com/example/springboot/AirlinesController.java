package com.example.springboot;

import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.Parameter;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.bind.annotation.CrossOrigin;

@RestController
@CrossOrigin(origins = {"http://localhost:3000", "http://frontend.povsim.svc.cluster.local:3000"})
public class AirlinesController {
	private static final Logger log = LoggerFactory.getLogger(AirlinesController.class);
	private static String[] airlines = { "AA", "DL", "UA" };

	@Operation(summary = "Index", description = "No-op hello world")
	@GetMapping("/")
	public String index() {
		return "Greetings from Spring Boot!";
	}

	@Operation(summary = "Health check", description = "Performs a simple health check")
	@GetMapping("/health")
	public String health() {
		return "Health check passed!";
	}

	@GetMapping("/airlines")
	@Operation(summary = "Get airlines", description = "Fetch a list of airlines")
	public String getUserById(
			@Parameter(description = "Optional flag - set raise to true to raise an exception")
			@RequestParam(value = "raise", required = false, defaultValue = "false") boolean raise) {
		if (raise) {
			throw new RuntimeException("Exception raised");
		}
		// Spring Boot's embedded Tomcat doesn't log a routine access line for
		// successful requests the way werkzeug does for flights -- without
		// this, a successful /airlines call (e.g. from flights' real
		// cross-service call in _fetch_operating_airlines) leaves zero log
		// evidence on this side, even though the trace itself is real. Logged
		// here, inside the handler, so MDC (auto-populated by the OTel Java
		// agent from the currently active span) is correctly attached.
		String airlinesList = String.join(", ", airlines);
		log.info("GET /airlines -> 200: returning {} operating airline(s): [{}]", airlines.length, airlinesList);
		return airlinesList;
	}
}
