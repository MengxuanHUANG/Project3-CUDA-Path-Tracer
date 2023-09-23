#pragma once

#include <glm/glm.hpp>

#include <GL/glew.h>
#include <GLFW/glfw3.h>

class GLFWwindow;
class ImGuiIO;
class SandBox;

class Application
{
public:
	Application(const glm::ivec2& win_size);
	~Application();

	bool Init();
	bool Run();

	void OnWindowResize(GLFWwindow* window, int w, int h);
	void OnMouseButton(GLFWwindow* window, int button, int action, int mods);
	void OnKey(GLFWwindow* window, int key, int scancode, int action, int mods);
	void OnMousePosition(GLFWwindow* window, double x, double y);

	void SetSandBox(SandBox* sandbox) { m_SandBox = sandbox; }

	static Application* GetApplication() { return s_Instance; }

private:
	void InitPBO();
	void InitVAO();
	void InitShader();

	void ResizeGL();

public:
	GLFWwindow* window;
	ImGuiIO* io;

	// Opengl handler
	GLuint positionLocation = 0;
	GLuint texcoordsLocation = 1;
	GLuint pbo;
	GLuint displayImage;

	glm::ivec2 m_Resolution;

	bool mouseOverImGuiWinow = false;

	SandBox* m_SandBox;
private:
	static Application* s_Instance;
};