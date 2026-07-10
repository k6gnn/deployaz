package az.deployaz.demo;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.boot.test.web.server.LocalManagementPort;
import org.springframework.test.web.servlet.MockMvc;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@AutoConfigureMockMvc
class HelloControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private TestRestTemplate restTemplate;

    @LocalManagementPort
    private int managementPort;

    @Test
    void helloEndpointReturnsMessage() throws Exception {
        mockMvc.perform(get("/api/hello"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.message").exists());
    }

    @Test
    void actuatorHealthIsUpOnManagementPort() {
        // Actuator lives on the separate management port (application.yml:
        // management.server.port=8081), not the public port -- this test
        // hits it the way Prometheus/kubelet actually would, rather than
        // through the main MockMvc context which no longer serves it.
        String url = "http://localhost:" + managementPort + "/actuator/health";
        var response = restTemplate.getForEntity(url, String.class);
        assertThat(response.getStatusCode().value()).isEqualTo(200);
        assertThat(response.getBody()).contains("\"status\":\"UP\"");
    }

    @Test
    void dbPasswordHealthDetailReportsNotRequiredInTests() {
        // deployaz.secrets.require defaults to false (see application.yml),
        // so tests never need a real Vault agent -- this confirms that
        // default holds and the detail is visible on the management port.
        String url = "http://localhost:" + managementPort + "/actuator/health";
        var response = restTemplate.getForEntity(url, String.class);
        assertThat(response.getBody()).contains("\"required\":false");
    }
}
